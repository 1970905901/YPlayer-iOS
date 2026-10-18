import { NativeAudioElement } from '@/services/nativeAudioElement';
import { nativeBridge } from '@/services/nativeBridge';
import { playbackDiagnostics } from '@/services/playbackDiagnostics';
import { resourceCacheService } from '@/services/resourceCacheService';
import type { AudioOutputDevice } from '@/types/audio';
import type { SongResult } from '@/types/music';
import { getTrackCoverUrl, isElectron } from '@/utils';

class AudioService {
  private audio: HTMLAudioElement;
  private currentTrack: SongResult | null = null;

  private context: AudioContext | null = null;
  private sourceNode: MediaElementAudioSourceNode | null = null;
  private filters: BiquadFilterNode[] = [];
  private gainNode: GainNode | null = null;
  private bypass = false;

  private playbackRate = 1.0;
  // 独立于 HTMLAudioElement 的真实状态：系统打断会造成 pause，但用户播放意图仍应保留。
  private userPlayIntent = false;
  private currentSinkId: string = 'default';
  private _isLoading = false;

  private operationLock = false;
  private operationLockTimer: ReturnType<typeof setTimeout> | null = null;
  private resumeInFlight: Promise<boolean> | null = null;

  // 当前一次加载（play）挂载在共享 audio 元素上的 canplay/error 监听器的清理函数。
  // 快速切歌时，上一首尚未结算的监听器必须在新一轮加载或 stop() 时移除，
  // 否则新歌 canplay 会同时触发旧歌的回调，导致"过期回调 stop 掉正在播放的新歌"卡死。
  private pendingLoadCleanup: (() => void) | null = null;

  private readonly frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

  private defaultEQSettings: { [key: string]: number } = {
    '31': 0,
    '62': 0,
    '125': 0,
    '250': 0,
    '500': 0,
    '1000': 0,
    '2000': 0,
    '4000': 0,
    '8000': 0,
    '16000': 0
  };

  // Event system
  private callbacks: { [key: string]: Function[] } = {};

  constructor() {
    // Create persistent audio element. iOS uses native AVPlayer so background
    // interruption recovery and Now Playing are not dependent on WKWebView execution.
    this.audio = nativeBridge.isIOS
      ? (new NativeAudioElement() as unknown as HTMLAudioElement)
      : new Audio();
    playbackDiagnostics.log('audio-service-init', {
      isIOS: nativeBridge.isIOS,
      mediaSession: this.supportsMediaSession
    });
    if (isElectron) {
      this.audio.crossOrigin = 'anonymous';
    }
    this.audio.preload = 'auto';

    // Bind native DOM events
    this.bindAudioEvents();

    if (this.supportsMediaSession) {
      this.initMediaSession();
    }

    // Restore EQ bypass state
    const bypassState = localStorage.getItem('eqBypass');
    this.bypass = bypassState ? JSON.parse(bypassState) : false;

    this.forceResetOperationLock();
    window.addEventListener('beforeunload', () => this.forceResetOperationLock());
  }

  // ==================== Native DOM Event Binding ====================

  private bindAudioEvents() {
    this.audio.addEventListener('play', () => {
      // 以元素真实状态为准，避免快速切歌时迟到的 play/pause 事件覆盖新状态。
      const isPlaying = !this.audio.paused && !this.audio.ended;
      if (isPlaying) this.userPlayIntent = true;
      this.updateMediaSessionState(isPlaying);
      if (isPlaying) this.emit('play');
    });

    this.audio.addEventListener('pause', () => {
      const isPlaying = !this.audio.paused && !this.audio.ended;
      this.updateMediaSessionState(isPlaying);
      if (!isPlaying) this.emit('pause');
    });

    this.audio.addEventListener('ended', () => {
      this.userPlayIntent = false;
      this.emit('end');
    });

    this.audio.addEventListener('seeked', () => {
      this.updateMediaSessionPositionState();
      this.emit('seek');
    });

    this.audio.addEventListener('loadedmetadata', () => {
      this.updateMediaSessionPositionState();
      this.syncNativePlayState(!this.audio.paused);
    });

    this.audio.addEventListener('durationchange', () => {
      this.updateMediaSessionPositionState();
      this.syncNativePlayState(!this.audio.paused);
    });

    this.audio.addEventListener('timeupdate', () => {
      // Consumers can listen to this if needed; mainly for MediaSession sync
    });

    this.audio.addEventListener('waiting', () => {
      this._isLoading = true;
    });

    this.audio.addEventListener('canplay', () => {
      this._isLoading = false;
    });

    this.audio.addEventListener('error', () => {
      const error = this.audio.error;
      console.error('Audio element error:', error?.code, error?.message);
      this.emit('audio_error', { type: 'media_error', error });
    });
  }

  // ==================== MediaSession ====================

  private get supportsMediaSession(): boolean {
    // iOS now uses native AVPlayer + MPNowPlayingInfoCenter exclusively.
    return (
      !nativeBridge.isIOS &&
      typeof navigator !== 'undefined' &&
      'mediaSession' in navigator &&
      typeof window.MediaMetadata === 'function'
    );
  }

  private updateNativeAudioMetadata(track: SongResult) {
    if (nativeBridge.isIOS || !track) return;
    const artists = track.ar
      ? track.ar.map((a) => a.name)
      : (track as any).song?.artists?.map((a: any) => a.name);
    const album = track.al ? track.al.name : (track as any).song?.album?.name;
    const duration =
      (track.dt ? track.dt / 1000 : 0) ||
      ((track as any).duration ? (track as any).duration / 1000 : 0);

    (this.audio as any).setMetadata?.({
      title: track.name || '',
      artist: artists ? artists.join(' / ') : '',
      album: album || '',
      artworkUrl: getTrackCoverUrl(track, '512y512'),
      duration: duration > 0 ? duration : undefined
    });
  }

  private initMediaSession() {
    navigator.mediaSession.setActionHandler('play', () => {
      this.resume();
    });

    navigator.mediaSession.setActionHandler('pause', () => {
      this.pause();
    });

    navigator.mediaSession.setActionHandler('stop', () => {
      this.pause();
    });

    navigator.mediaSession.setActionHandler('seekto', (event) => {
      if (event.seekTime !== undefined) {
        this.seek(event.seekTime);
      }
    });

    // 显式将 seekbackward / seekforward 置空，防止 iOS WebKit 将控制中心强制替换为 15 秒快进快退
    try {
      navigator.mediaSession.setActionHandler('seekbackward', null);
      navigator.mediaSession.setActionHandler('seekforward', null);
    } catch {
      // ignore
    }

    navigator.mediaSession.setActionHandler('previoustrack', () => {
      this.emit('previoustrack');
    });

    navigator.mediaSession.setActionHandler('nexttrack', () => {
      this.emit('nexttrack');
    });
  }

  private currentLyric: string = '';
  private currentMediaSessionTrackKey: string = '';
  private currentMediaSessionArtwork: { src: string; type: string; sizes: string }[] = [];
  private mediaSessionMetadataToken = 0;
  private mediaSessionNudgeTimers: ReturnType<typeof setTimeout>[] = [];
  private nativeTrackKey: string = '';
  private preloadedArtworkUrls = new Set<string>();

  /** 提前把 Media Session 会用到的各档封面放入 WebKit 缓存，避免小卡片先出现空白图。 */
  public preloadMediaSessionArtwork(track: SongResult) {
    if (!nativeBridge.isIOS || !track) return;

    if (this.preloadedArtworkUrls.size > 120) {
      this.preloadedArtworkUrls.clear();
    }

    for (const size of ['96y96', '128y128', '256y256', '384y384', '512y512', '800y800']) {
      const url = getTrackCoverUrl(track, size);
      if (!url || this.preloadedArtworkUrls.has(url)) continue;
      this.preloadedArtworkUrls.add(url);

      const image = new Image();
      image.decoding = 'async';
      image.onerror = () => this.preloadedArtworkUrls.delete(url);
      image.src = url;
    }
  }

  /**
   * 更新当前单句歌词到系统媒体中心与锁屏
   */
  public updateCurrentLyric(text: string) {
    const trimmed = (text || '').trim();
    this.currentLyric = trimmed;

    if (nativeBridge.isIOS) {
      (this.audio as any).updateLyric?.(trimmed);
      return;
    }

    try {
      if (this.supportsMediaSession) {
        // MediaMetadata 属性只读，整体替换以刷新歌词，同时保留当前 artwork。
        this.setMediaSessionMetadata(this.currentMediaSessionArtwork);
      }
    } catch {
      // ignore
    }

    try {
      const curTime = isFinite(this.audio?.currentTime) ? this.audio.currentTime : 0;
      const duration = isFinite(this.audio?.duration) ? this.audio.duration : 0;
      nativeBridge.updateLyric(trimmed, curTime, duration);
    } catch {
      // ignore
    }
  }

  private setMediaSessionMetadata(
    artwork: { src: string; type: string; sizes: string }[],
    cacheBustToken?: number
  ) {
    const track = this.currentTrack;
    if (!track || !this.supportsMediaSession) return;

    const artists = track.ar
      ? track.ar.map((a) => a.name)
      : (track as any).song?.artists?.map((a: any) => a.name);
    const artistsStr = artists ? artists.join(' / ') : '';
    const album = track.al ? track.al.name : (track as any).song?.album?.name;
    const combinedTitle = artistsStr ? `${track.name || ''} - ${artistsStr}` : track.name || '';
    const effectiveArtwork = cacheBustToken
      ? artwork.map((item) => ({
          ...item,
          src: this.cacheBustArtworkUrl(item.src, cacheBustToken)
        }))
      : artwork;

    navigator.mediaSession.metadata = new window.MediaMetadata({
      title: combinedTitle,
      artist: this.currentLyric || artistsStr || ' ',
      album: album || '',
      artwork: effectiveArtwork
    });
    playbackDiagnostics.log('media-session-metadata', {
      title: combinedTitle,
      cacheBust: !!cacheBustToken,
      artwork: effectiveArtwork.map((item) => ({ sizes: item.sizes, src: item.src }))
    });
  }

  private cacheBustArtworkUrl(url: string, token: number): string {
    if (!/^https?:\/\//i.test(url)) return url;
    return `${url}${url.includes('#') ? '&' : '#'}np=${token}`;
  }

  /**
   * iOS 有时在首次建卡时不绘制小封面，直到视图重新布局才显示。
   * 封面加载完成后主动重发 metadata，模拟一次无感重绘。
   */
  private scheduleMediaSessionArtworkNudge(
    artwork: { src: string; type: string; sizes: string }[]
  ) {
    if (!nativeBridge.isIOS || !this.supportsMediaSession) return;

    this.mediaSessionMetadataToken += 1;
    const token = this.mediaSessionMetadataToken;
    this.mediaSessionNudgeTimers.forEach((timer) => clearTimeout(timer));
    this.mediaSessionNudgeTimers = [];

    for (const delay of [700, 2200]) {
      const timer = setTimeout(() => {
        if (token !== this.mediaSessionMetadataToken) return;
        try {
          this.setMediaSessionMetadata(artwork, token);
        } catch {
          // ignore
        }
      }, delay);
      this.mediaSessionNudgeTimers.push(timer);
    }
  }

  private updateMediaSessionMetadata(track: SongResult) {
    if (nativeBridge.isIOS) {
      this.updateNativeAudioMetadata(track);
      return;
    }

    try {
      if (!this.supportsMediaSession) {
        // iOS 14/15 的 WKWebView 可能缺少 Media Session / MediaMetadata，原生控制中心仍需完整元数据。
        this.syncNativePlayState(!this.audio.paused);
        return;
      }

      const artists = track.ar
        ? track.ar.map((a) => a.name)
        : (track as any).song?.artists?.map((a: any) => a.name);
      const artistsStr = artists ? artists.join(' / ') : '';
      const album = track.al ? track.al.name : (track as any).song?.album?.name;

      // 切歌时清空上一首歌词，避免新歌首帧沿用旧歌词。
      const trackKey = `${track.id || ''}|${track.name || ''}|${artistsStr}|${album || ''}`;
      if (trackKey !== this.currentMediaSessionTrackKey) {
        this.currentMediaSessionTrackKey = trackKey;
        this.currentLyric = '';
      }

      // iOS 小尺寸 Control Center 卡片会优先读取前项；必须在前面提供真实小图，
      // 同时保留末尾高清图供展开卡片和锁屏使用。
      const coverUrl96 = getTrackCoverUrl(track, '96y96');
      const coverUrl128 = getTrackCoverUrl(track, '128y128');
      const coverUrl256 = getTrackCoverUrl(track, '256y256');
      const coverUrl384 = getTrackCoverUrl(track, '384y384');
      const coverUrl512 = getTrackCoverUrl(track, '512y512');
      const coverUrl800 = getTrackCoverUrl(track, '800y800');

      const standardArtwork = [
        { src: coverUrl96, type: 'image/jpeg', sizes: '96x96' },
        { src: coverUrl128, type: 'image/jpeg', sizes: '128x128' },
        { src: coverUrl256, type: 'image/jpeg', sizes: '256x256' },
        { src: coverUrl384, type: 'image/jpeg', sizes: '384x384' },
        { src: coverUrl512, type: 'image/jpeg', sizes: '512x512' },
        { src: coverUrl800, type: 'image/jpeg', sizes: '800x800' }
      ].filter((item) => !!item.src);

      // iOS 的 Media Session 只稳定使用第一张图。用高清源伪装成小图，
      // 小卡片会缩放绘制，展开时仍使用同一张高清位图，避免空白或放大后模糊。
      const artwork =
        nativeBridge.isIOS && coverUrl512
          ? [{ src: coverUrl512, type: 'image/jpeg', sizes: '96x96' }]
          : standardArtwork;

      this.currentMediaSessionArtwork = artwork;
      this.setMediaSessionMetadata(artwork);
      this.scheduleMediaSessionArtworkNudge(artwork);

      // 每次切换歌曲时再次确保禁用 15 秒快进快退，激活上一首/下一首/播放/暂停核心交互
      try {
        navigator.mediaSession.setActionHandler('seekbackward', null);
        navigator.mediaSession.setActionHandler('seekforward', null);
        navigator.mediaSession.setActionHandler('play', () => {
          this.resume();
        });
        navigator.mediaSession.setActionHandler('pause', () => {
          this.pause();
        });
        navigator.mediaSession.setActionHandler('stop', () => {
          this.pause();
        });
        navigator.mediaSession.setActionHandler('seekto', (event) => {
          if (event.seekTime !== undefined) {
            this.seek(event.seekTime);
          }
        });
        navigator.mediaSession.setActionHandler('previoustrack', () => {
          this.emit('previoustrack');
        });
        navigator.mediaSession.setActionHandler('nexttrack', () => {
          this.emit('nexttrack');
        });
      } catch {
        // ignore
      }

      this.syncNativePlayState(!this.audio.paused);
    } catch (error) {
      console.error('更新媒体会话元数据时出错:', error);
      // Media Session 异常不能阻断原生控制中心的元数据同步。
      this.syncNativePlayState(!this.audio.paused);
    }
  }

  private updateMediaSessionState(isPlaying: boolean) {
    if (this.supportsMediaSession) {
      navigator.mediaSession.playbackState = isPlaying ? 'playing' : 'paused';
    }
    this.updateMediaSessionPositionState();
    this.syncNativePlayState(isPlaying);
  }

  private updateMediaSessionPositionState() {
    try {
      if (this.supportsMediaSession && this.audio.duration && isFinite(this.audio.duration)) {
        if ('setPositionState' in navigator.mediaSession) {
          navigator.mediaSession.setPositionState({
            duration: this.audio.duration,
            playbackRate: this.audio.paused ? 0 : this.audio.playbackRate,
            position: this.audio.currentTime
          });
        }
      }
    } catch (error) {
      console.error('更新媒体会话位置状态时出错:', error);
    }
  }

  /**
   * 同步播放状态到 iOS 原生锁屏与控制中心
   */
  private syncNativePlayState(isPlaying?: boolean) {
    // iOS metadata, progress, and remote commands are owned by NativeAudioManager.
    if (nativeBridge.isIOS) return;
    if (!this.currentTrack) return;
    try {
      const artists = this.currentTrack.ar
        ? this.currentTrack.ar.map((a) => a.name)
        : (this.currentTrack as any).song?.artists?.map((a: any) => a.name);
      const album = this.currentTrack.al
        ? this.currentTrack.al.name
        : (this.currentTrack as any).song?.album?.name;
      // 原生控制中心使用 500px 首图，避免大图下载超时导致封面空白。
      const picUrl = getTrackCoverUrl(this.currentTrack, '500y500');
      if (picUrl && this.currentTrack.id) {
        void resourceCacheService.trackResource(
          `song_cover_${this.currentTrack.id}`,
          picUrl,
          0,
          'cover'
        );
      }

      const trackDurationSec =
        (this.currentTrack.dt ? this.currentTrack.dt / 1000 : 0) ||
        ((this.currentTrack as any).duration ? (this.currentTrack as any).duration / 1000 : 0);
      const duration =
        isFinite(this.audio.duration) && this.audio.duration > 0
          ? this.audio.duration
          : trackDurationSec;

      const activeIsPlaying = isPlaying !== undefined ? isPlaying : !this.audio.paused;
      const nativeTrackKey = `${this.currentTrack.id || ''}|${this.currentTrack.name || ''}`;
      const trackChanged = nativeTrackKey !== this.nativeTrackKey;
      if (trackChanged) {
        this.nativeTrackKey = nativeTrackKey;
      }
      const nativeCurrentTime =
        trackChanged || !isFinite(this.audio.currentTime) ? 0 : this.audio.currentTime;

      nativeBridge.updatePlayState({
        isPlaying: activeIsPlaying,
        userPlayIntent: this.userPlayIntent,
        mediaSessionAvailable: this.supportsMediaSession,
        title: this.currentTrack.name || '',
        artist: artists ? artists.join(' / ') : '',
        album: album || '',
        artworkUrl: picUrl,
        duration: duration > 0 ? duration : 0,
        currentTime: nativeCurrentTime,
        playbackRate: this.playbackRate
      });
    } catch (e) {
      console.warn('[AudioService] syncNativePlayState error:', e);
    }
  }

  // ==================== Event Emitter ====================

  private emit(event: string, ...args: any[]) {
    const eventCallbacks = this.callbacks[event];
    if (eventCallbacks) {
      eventCallbacks.forEach((callback) => callback(...args));
    }
  }

  on(event: string, callback: Function) {
    if (!this.callbacks[event]) {
      this.callbacks[event] = [];
    }
    this.callbacks[event].push(callback);
  }

  off(event: string, callback: Function) {
    const eventCallbacks = this.callbacks[event];
    if (eventCallbacks) {
      this.callbacks[event] = eventCallbacks.filter((cb) => cb !== callback);
    }
  }

  clearAllListeners() {
    this.callbacks = {};
  }

  // ==================== EQ ====================

  private setupEQ() {
    if (this.sourceNode) return; // Already initialized

    if (!isElectron) {
      console.log('Web环境中跳过EQ设置，避免CORS问题');
      this.bypass = true;
      return;
    }

    try {
      this.context = new AudioContext();
      this.sourceNode = this.context.createMediaElementSource(this.audio);
      this.gainNode = this.context.createGain();

      // Create 10-band filter chain
      const savedSettings = this.loadEQSettings();
      this.filters = this.frequencies.map((freq) => {
        const filter = this.context!.createBiquadFilter();
        filter.type = 'peaking';
        filter.frequency.value = freq;
        filter.Q.value = 1;
        filter.gain.value = savedSettings[freq.toString()] || 0;
        return filter;
      });

      // Wire up the graph
      this.applyBypassState();

      // Apply saved volume
      const savedVolume = localStorage.getItem('volume');
      this.applyVolume(savedVolume ? parseFloat(savedVolume) : 1);

      // Monitor context state
      this.setupContextStateMonitoring();

      // Restore saved audio device
      this.restoreSavedAudioDevice();

      console.log('EQ initialization successful');
    } catch (error) {
      console.error('EQ initialization failed:', error);
      // Fallback: connect audio directly (no EQ)
      this.sourceNode = null;
      this.context = null;
    }
  }

  private applyBypassState() {
    if (!this.sourceNode || !this.gainNode || !this.context) return;

    try {
      // Disconnect all
      try {
        this.sourceNode.disconnect();
      } catch {
        /* already disconnected */
      }
      this.filters.forEach((filter) => {
        try {
          filter.disconnect();
        } catch {
          /* already disconnected */
        }
      });
      try {
        this.gainNode.disconnect();
      } catch {
        /* already disconnected */
      }

      if (this.bypass) {
        // EQ disabled: source -> gain -> destination
        this.sourceNode.connect(this.gainNode);
        this.gainNode.connect(this.context.destination);
      } else {
        // EQ enabled: source -> filters[0] -> ... -> filters[9] -> gain -> destination
        this.sourceNode.connect(this.filters[0]);
        this.filters.forEach((filter, index) => {
          if (index < this.filters.length - 1) {
            filter.connect(this.filters[index + 1]);
          }
        });
        this.filters[this.filters.length - 1].connect(this.gainNode);
        this.gainNode.connect(this.context.destination);
      }
    } catch (error) {
      console.error('Error applying EQ state, attempting fallback:', error);
      try {
        if (this.sourceNode && this.context) {
          this.sourceNode.connect(this.context.destination);
        }
      } catch (fallbackError) {
        console.error('Fallback connection also failed:', fallbackError);
        this.emit('audio_error', { type: 'graph_disconnected', error: fallbackError });
      }
    }
  }

  public isEQEnabled(): boolean {
    return !this.bypass;
  }

  public setEQEnabled(enabled: boolean) {
    this.bypass = !enabled;
    localStorage.setItem('eqBypass', JSON.stringify(this.bypass));

    if (this.sourceNode && this.gainNode && this.context) {
      this.applyBypassState();
    }
  }

  public setEQFrequencyGain(frequency: string, gain: number) {
    const filterIndex = this.frequencies.findIndex((f) => f.toString() === frequency);
    if (filterIndex !== -1 && this.filters[filterIndex]) {
      this.filters[filterIndex].gain.setValueAtTime(gain, this.context?.currentTime || 0);
      this.saveEQSettings(frequency, gain);
    }
  }

  public resetEQ() {
    this.filters.forEach((filter) => {
      filter.gain.setValueAtTime(0, this.context?.currentTime || 0);
    });
    localStorage.removeItem('eqSettings');
  }

  public getAllEQSettings(): { [key: string]: number } {
    return this.loadEQSettings();
  }

  public getCurrentPreset(): string | null {
    return localStorage.getItem('currentPreset');
  }

  public setCurrentPreset(preset: string): void {
    localStorage.setItem('currentPreset', preset);
  }

  private saveEQSettings(frequency: string, gain: number) {
    const settings = this.loadEQSettings();
    settings[frequency] = gain;
    localStorage.setItem('eqSettings', JSON.stringify(settings));
  }

  private loadEQSettings(): { [key: string]: number } {
    const savedSettings = localStorage.getItem('eqSettings');
    return savedSettings ? JSON.parse(savedSettings) : { ...this.defaultEQSettings };
  }

  // ==================== Operation Lock ====================

  private setOperationLock(): boolean {
    if (this.operationLock) {
      return false;
    }
    this.operationLock = true;

    if (this.operationLockTimer) clearTimeout(this.operationLockTimer);
    this.operationLockTimer = setTimeout(() => {
      console.warn('操作锁超时自动释放');
      this.releaseOperationLock();
    }, 5000);

    return true;
  }

  public releaseOperationLock(): void {
    this.operationLock = false;
    if (this.operationLockTimer) {
      clearTimeout(this.operationLockTimer);
      this.operationLockTimer = null;
    }
  }

  public forceResetOperationLock(): void {
    this.operationLock = false;
    if (this.operationLockTimer) {
      clearTimeout(this.operationLockTimer);
      this.operationLockTimer = null;
    }
  }

  // ==================== Playback Control ====================

  public play(
    url: string,
    track: SongResult,
    isPlay: boolean = true,
    seekTime: number = 0,
    _existingSound?: HTMLAudioElement
  ): Promise<HTMLAudioElement> {
    // Resume current playback if no new URL/track provided
    if (this.audio.src && !url && !track) {
      this.audio.play();
      return Promise.resolve(this.audio);
    }

    this.forceResetOperationLock();
    this.setOperationLock();

    if (!url || !track) {
      this.releaseOperationLock();
      return Promise.reject(new Error('缺少必要参数: url和track'));
    }

    // Check if same URL — just resume/seek
    const currentSrc = this.audio.src;
    const isSameUrl = currentSrc && currentSrc === url;
    this.userPlayIntent = isPlay;

    if (isSameUrl) {
      this.currentTrack = track;
      this.updateNativeAudioMetadata(track);
      if (seekTime > 0) this.audio.currentTime = seekTime;
      if (isPlay) {
        void this.audio.play().catch((error) => {
          console.error('Audio play failed:', error);
          this.updateMediaSessionState(false);
          this.emit('playerror', { track, error });
          this.emit('pause');
        });
      }
      this.updateMediaSessionMetadata(track);
      this.releaseOperationLock();
      return Promise.resolve(this.audio);
    }

    // 开始新一轮加载前，先移除上一轮尚未结算的加载监听器，避免污染新歌
    if (this.pendingLoadCleanup) {
      this.pendingLoadCleanup();
      this.pendingLoadCleanup = null;
    }

    return new Promise<HTMLAudioElement>((resolve, reject) => {
      let retryCount = 0;
      const maxRetries = 1;

      const tryPlay = () => {
        this._isLoading = true;
        this.currentTrack = track;

        // 先同步歌曲元数据供原生预取封面；实际播放状态由 audio 的 play/pause 事件驱动。
        this.syncNativePlayState(!this.audio.paused);

        // Ensure EQ/AudioContext is set up (only runs once)
        this.setupEQ();

        // Resume AudioContext if suspended (user gesture requirement)
        if (this.context && this.context.state === 'suspended') {
          this.context.resume().catch((e) => console.warn('Failed to resume AudioContext:', e));
        }

        const onCanPlay = () => {
          cleanup();
          this._isLoading = false;

          if (seekTime > 0) {
            this.audio.currentTime = seekTime;
          }

          if (isPlay) {
            void this.audio.play().catch((err) => {
              console.error('Audio play failed:', err);
              this.updateMediaSessionState(false);
              this.emit('playerror', { track, error: err });
              this.emit('pause');
            });
          }

          // Apply volume (use GainNode if available, else direct)
          const savedVolume = localStorage.getItem('volume');
          this.applyVolume(savedVolume ? parseFloat(savedVolume) : 1);

          this.audio.playbackRate = this.playbackRate;
          this.updateMediaSessionMetadata(track);
          this.updateMediaSessionPositionState();
          this.syncNativePlayState(!this.audio.paused);
          this.emit('load');
          this.releaseOperationLock();
          resolve(this.audio);
        };

        const onError = () => {
          cleanup();
          this._isLoading = false;
          const error = this.audio.error;
          console.error('Audio load error:', error?.code, error?.message);
          this.syncNativePlayState(false);
          this.emit('loaderror', { track, error });

          // MEDIA_ERR_SRC_NOT_SUPPORTED(4)：源本身无效（URL 已失效/返回了
          // 非音频内容），用同一 URL 重试毫无意义，直接走 url_expired 换新 URL
          const isSrcNotSupported = error?.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED;

          if (!isSrcNotSupported && retryCount < maxRetries) {
            retryCount++;
            console.log(`Retrying playback (${retryCount}/${maxRetries})...`);
            setTimeout(tryPlay, 1000 * retryCount);
          } else {
            this.emit('url_expired', track);
            this.releaseOperationLock();
            reject(new Error('音频加载失败，请尝试切换其他歌曲'));
          }
        };

        const cleanup = () => {
          this.audio.removeEventListener('canplay', onCanPlay);
          this.audio.removeEventListener('error', onError);
          if (this.pendingLoadCleanup === cleanup) {
            this.pendingLoadCleanup = null;
          }
        };

        // 记录本轮清理函数，供下一次 play()/stop() 在结算前主动移除
        this.pendingLoadCleanup = cleanup;

        this.audio.addEventListener('canplay', onCanPlay, { once: true });
        this.audio.addEventListener('error', onError, { once: true });

        // Change source and load
        this.audio.src = url;
        this.updateNativeAudioMetadata(track);
        this.audio.load();
      };

      tryPlay();
    }).finally(() => {
      this.releaseOperationLock();
    });
  }

  public resume(): Promise<boolean> {
    return this.resumeWithStrategy(false);
  }

  /** 系统打断恢复必须重建媒体元素，才能让 WebKit 重新注册 Now Playing 卡片。 */
  public resumeAfterInterruption(): Promise<boolean> {
    return this.resumeWithStrategy(true);
  }

  private async resumeWithStrategy(forceReload: boolean): Promise<boolean> {
    // 原生打断恢复会多次重试；同一时间只允许一个恢复流程，避免重复 play 互相打断。
    if (this.resumeInFlight) return this.resumeInFlight;

    const resumePromise = this.performResume(forceReload);
    this.resumeInFlight = resumePromise;
    try {
      return await resumePromise;
    } finally {
      if (this.resumeInFlight === resumePromise) {
        this.resumeInFlight = null;
      }
    }
  }

  private async performResume(forceReload: boolean): Promise<boolean> {
    this.forceResetOperationLock();
    this.userPlayIntent = true;

    playbackDiagnostics.log('resume-start', {
      forceReload,
      paused: this.audio.paused,
      currentTime: this.audio.currentTime,
      readyState: this.audio.readyState,
      visibility: document.visibilityState,
      hasSrc: !!this.audio.src
    });

    const track = this.currentTrack;
    if (!track || !this.audio.src) {
      playbackDiagnostics.log('resume-aborted', { hasTrack: !!track, hasSrc: !!this.audio.src });
      return false;
    }

    // 打断后 WebKit 可能已清空 Media Session；播放前先重新建立元数据与远程控制。
    this.refreshMediaSession();

    if (!forceReload) {
      try {
        await this.audio.play();
        playbackDiagnostics.log('resume-direct-result', { paused: this.audio.paused });
        if (!this.audio.paused) {
          this.refreshMediaSession();
          return true;
        }
      } catch (error) {
        playbackDiagnostics.log('resume-direct-error', { error: String(error) });
        console.warn('[AudioService] 直接恢复播放失败，尝试重建媒体元素:', error);
      }
    }

    const recovered = await this.reloadAndResumeAfterInterruption();
    if (recovered) return true;

    if (forceReload) {
      // 重建失败时再给原媒体元素一次直接恢复机会。
      try {
        await this.audio.play();
        if (!this.audio.paused) {
          this.refreshMediaSession();
          return true;
        }
      } catch (error) {
        console.warn('[AudioService] 重建后直接恢复仍失败:', error);
      }
    }

    playbackDiagnostics.log('resume-failed');
    this.updateMediaSessionState(false);
    this.emit('pause');
    return false;
  }

  /** 打断可能让 HTMLMediaElement 进入无法直接 play 的状态；重设同一 src 重建 WebKit 媒体会话。 */
  private reloadAndResumeAfterInterruption(): Promise<boolean> {
    const source = this.audio.src;
    if (!source) return Promise.resolve(false);

    const resumePosition = isFinite(this.audio.currentTime) ? this.audio.currentTime : 0;
    const resumeRate = this.playbackRate;
    playbackDiagnostics.log('media-reload-start', { resumePosition, resumeRate });

    if (this.pendingLoadCleanup) {
      this.pendingLoadCleanup();
      this.pendingLoadCleanup = null;
    }

    return new Promise<boolean>((resolve) => {
      let settled = false;
      let timeoutId: ReturnType<typeof setTimeout> | null = null;

      const cleanup = () => {
        this.audio.removeEventListener('loadedmetadata', onReady);
        this.audio.removeEventListener('error', onError);
        if (timeoutId) {
          clearTimeout(timeoutId);
          timeoutId = null;
        }
      };

      const finish = (success: boolean) => {
        if (settled) return;
        settled = true;
        cleanup();
        if (success) this.refreshMediaSession();
        resolve(success);
      };

      const onReady = () => {
        playbackDiagnostics.log('media-reload-ready', {
          readyState: this.audio.readyState,
          duration: this.audio.duration
        });
        try {
          if (resumePosition > 0) this.audio.currentTime = resumePosition;
          this.audio.playbackRate = resumeRate;
        } catch (error) {
          console.warn('[AudioService] 恢复播放进度失败:', error);
        }

        void this.audio
          .play()
          .then(() => {
            this.userPlayIntent = true;
            playbackDiagnostics.log('media-reload-play-result', { paused: this.audio.paused });
            finish(!this.audio.paused);
          })
          .catch((error) => {
            playbackDiagnostics.log('media-reload-play-error', { error: String(error) });
            console.warn('[AudioService] 重建媒体元素后播放失败:', error);
            finish(false);
          });
      };

      const onError = () => finish(false);

      timeoutId = setTimeout(() => finish(false), 12000);
      this.audio.addEventListener('loadedmetadata', onReady, { once: true });
      this.audio.addEventListener('error', onError, { once: true });

      try {
        this.audio.src = source;
        this.audio.load();
      } catch (error) {
        console.warn('[AudioService] 重建媒体元素失败:', error);
        finish(false);
      }
    });
  }

  /** 让 WebKit 重新持有 Now Playing 卡片、封面和手动远程控制。 */
  public refreshMediaSession() {
    if (!this.currentTrack) return;
    this.updateMediaSessionMetadata(this.currentTrack);
    this.updateMediaSessionState(!this.audio.paused);
  }

  public pause() {
    this.forceResetOperationLock();
    this.userPlayIntent = false;
    try {
      this.audio.pause();
    } catch (error) {
      console.error('暂停音频失败:', error);
    }
  }

  /** 系统打断专用：停止发声，但保留用户播放意图供打断结束后恢复。 */
  public pauseForInterruption() {
    this.forceResetOperationLock();
    playbackDiagnostics.log('interruption-pause', {
      paused: this.audio.paused,
      currentTime: this.audio.currentTime
    });
    try {
      this.audio.pause();
    } catch (error) {
      console.error('系统打断暂停音频失败:', error);
    }
  }

  public stop() {
    this.forceResetOperationLock();
    this.userPlayIntent = false;
    // 移除尚未结算的加载监听器，避免 stop 后旧的 canplay/error 仍触发过期回调
    if (this.pendingLoadCleanup) {
      this.pendingLoadCleanup();
      this.pendingLoadCleanup = null;
    }
    try {
      this.audio.pause();
      this.audio.removeAttribute('src');
      this.audio.load(); // Reset the element
    } catch (error) {
      console.error('停止音频失败:', error);
    }
    this.currentTrack = null;
    this.currentLyric = '';
    this.currentMediaSessionTrackKey = '';
    this.currentMediaSessionArtwork = [];
    this.mediaSessionMetadataToken += 1;
    this.mediaSessionNudgeTimers.forEach((timer) => clearTimeout(timer));
    this.mediaSessionNudgeTimers = [];
    this.nativeTrackKey = '';
    if (this.supportsMediaSession) {
      navigator.mediaSession.playbackState = 'none';
    }
  }

  public seek(time: number) {
    this.forceResetOperationLock();
    try {
      const targetTime = Math.max(0, time);
      this.emit('seek_start', targetTime);
      this.audio.currentTime = targetTime;
      this.updateMediaSessionPositionState();
      this.syncNativePlayState(!this.audio.paused);
      this.emit('seek', targetTime);
    } catch (error) {
      console.error('Seek操作失败:', error);
    }
  }

  public setVolume(volume: number) {
    this.applyVolume(volume);
  }

  private applyVolume(volume: number) {
    const normalizedVolume = Math.max(0, Math.min(1, volume));

    if (this.gainNode && this.context) {
      this.gainNode.gain.cancelScheduledValues(this.context.currentTime);
      this.gainNode.gain.setValueAtTime(normalizedVolume, this.context.currentTime);
    } else {
      // Fallback: direct volume (no Web Audio context)
      this.audio.volume = normalizedVolume;
    }

    localStorage.setItem('volume', normalizedVolume.toString());
  }

  public setPlaybackRate(rate: number) {
    const normalizedRate = Math.max(0.25, Math.min(4, rate));
    this.playbackRate = normalizedRate;
    this.audio.playbackRate = normalizedRate;
    this.updateMediaSessionPositionState();
    this.syncNativePlayState(!this.audio.paused);
  }

  public getPlaybackRate(): number {
    return this.playbackRate;
  }

  // ==================== State Queries ====================

  getCurrentSound(): HTMLAudioElement | null {
    return this.audio.src ? this.audio : null;
  }

  isPlaying(): boolean {
    return !this.audio.paused && !this.audio.ended;
  }

  getCurrentTrack(): SongResult | null {
    return this.currentTrack;
  }

  isLoading(): boolean {
    return this._isLoading || this.operationLock;
  }

  isActuallyPlaying(): boolean {
    if (!this.audio.src) return false;
    try {
      const isPlaying = !this.audio.paused && !this.audio.ended;
      const contextOk = !this.context || this.context.state === 'running';
      return isPlaying && !this._isLoading && contextOk;
    } catch (error) {
      console.error('检查播放状态出错:', error);
      return false;
    }
  }

  // ==================== Audio Output Devices ====================

  public async getAudioOutputDevices(): Promise<AudioOutputDevice[]> {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const audioOutputs = devices.filter((d) => d.kind === 'audiooutput');

      return audioOutputs.map((device, index) => ({
        deviceId: device.deviceId,
        label: device.label || `Speaker ${index + 1}`,
        isDefault: device.deviceId === 'default' || device.deviceId === ''
      }));
    } catch (error) {
      console.error('枚举音频设备失败:', error);
      return [{ deviceId: 'default', label: 'Default', isDefault: true }];
    }
  }

  public async setAudioOutputDevice(deviceId: string): Promise<boolean> {
    try {
      if (this.context && typeof (this.context as any).setSinkId === 'function') {
        await (this.context as any).setSinkId(deviceId);
        this.currentSinkId = deviceId;
        localStorage.setItem('audioOutputDeviceId', deviceId);
        console.log('音频输出设备已切换:', deviceId);
        return true;
      } else {
        console.warn('AudioContext.setSinkId 不可用');
        return false;
      }
    } catch (error) {
      console.error('设置音频输出设备失败:', error);
      return false;
    }
  }

  public getCurrentSinkId(): string {
    return this.currentSinkId;
  }

  private async restoreSavedAudioDevice(): Promise<void> {
    const savedDeviceId = localStorage.getItem('audioOutputDeviceId');
    if (savedDeviceId && savedDeviceId !== 'default') {
      try {
        await this.setAudioOutputDevice(savedDeviceId);
      } catch (error) {
        console.warn('恢复音频输出设备失败，回退到默认设备:', error);
        localStorage.removeItem('audioOutputDeviceId');
        this.currentSinkId = 'default';
      }
    }
  }

  private setupContextStateMonitoring() {
    if (!this.context) return;

    this.context.addEventListener('statechange', async () => {
      console.log('AudioContext state changed:', this.context?.state);

      if (this.context?.state === 'suspended' && !this.audio.paused) {
        console.log('AudioContext suspended while playing, attempting to resume...');
        try {
          await this.context.resume();
          console.log('AudioContext resumed successfully');
        } catch (e) {
          console.error('Failed to resume AudioContext:', e);
          this.emit('audio_error', { type: 'context_suspended', error: e });
        }
      } else if (this.context?.state === 'closed') {
        console.warn('AudioContext was closed unexpectedly');
        this.emit('audio_error', { type: 'context_closed' });
      }
    });
  }
}

export const audioService = new AudioService();
