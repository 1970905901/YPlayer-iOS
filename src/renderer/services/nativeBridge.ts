/**
 * Native Bridge for iOS (AlgerMusicPlayer iOS)
 * 遵循 Emil Kowalski 设计工程与 Apple Design 规范
 * 负责与 iOS 原生 Swift 容器（WKWebView / MediaPlayer / AVFoundation / HapticFeedback）进行双向通信
 */

export interface PlaybackStatePayload {
  isPlaying: boolean;
  title: string;
  artist: string;
  album?: string;
  artworkUrl?: string;
  duration: number;
  currentTime: number;
  playbackRate?: number;
}

export type HapticStyle =
  'light' | 'medium' | 'heavy' | 'selection' | 'success' | 'warning' | 'error';

class NativeBridge {
  /**
   * 判断是否运行在 iOS 原生 WKWebView 容器中
   */
  public get isIOS(): boolean {
    if (typeof window === 'undefined') return false;
    const win = window as any;
    return !!(win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.nativePlayer);
  }

  constructor() {
    this.initGlobalHandler();
  }

  /**
   * 初始化挂载到 window.__NATIVE_BRIDGE__ 的命令分发器
   */
  private initGlobalHandler() {
    if (typeof window === 'undefined') return;

    (window as any).__NATIVE_BRIDGE__ = {
      handleRemoteCommand: (command: string, arg?: any) => {
        this.dispatchRemoteCommand(command, arg);
      }
    };
  }

  /**
   * 向原生端发送消息
   */
  private postMessage(action: string, payload: any = {}) {
    if (!this.isIOS) return;
    try {
      (window as any).webkit.messageHandlers.nativePlayer.postMessage({
        action,
        ...payload
      });
    } catch (e) {
      console.warn('[NativeBridge] postMessage failed:', e);
    }
  }

  /**
   * 同步播放状态到原生锁屏控制与 Control Center (MPNowPlayingInfoCenter)
   */
  public updatePlayState(state: PlaybackStatePayload) {
    if (!this.isIOS) return;
    this.postMessage('updatePlayState', {
      isPlaying: state.isPlaying,
      title: state.title || '未知曲目',
      artist: state.artist || '未知艺术家',
      album: state.album || '',
      artworkUrl: state.artworkUrl || '',
      duration: Math.max(0, state.duration || 0),
      currentTime: Math.max(0, state.currentTime || 0),
      playbackRate: state.playbackRate || 1.0
    });
  }

  /**
   * 触发原生震动触觉反馈 (UIFeedbackGenerator)
   */
  public triggerHaptic(style: HapticStyle = 'selection') {
    if (!this.isIOS) return;
    this.postMessage('hapticFeedback', { style });
  }

  /**
   * 动态设置状态栏明暗样式 (UIStatusBarStyle)
   */
  public setStatusBarStyle(style: 'light' | 'dark') {
    if (!this.isIOS) return;
    this.postMessage('setStatusBarStyle', { style });
  }

  /**
   * 调用 iOS 原生分享面板 (UIActivityViewController)
   */
  public share(title: string, url: string) {
    if (!this.isIOS) return;
    this.postMessage('share', { title, url });
  }

  /**
   * 同步当前单句歌词到 iOS 原生锁屏、控制中心与灵动岛
   */
  public updateLyric(text: string, currentTime?: number, duration?: number) {
    if (!this.isIOS) return;
    this.postMessage('updateLyric', { text, currentTime, duration });
  }

  /**
   * 清除 iOS 原生 URLCache 与锁屏封面缓存
   */
  public clearNativeCache() {
    if (!this.isIOS) return;
    this.postMessage('clearNativeCache');
  }

  /**
   * 设置 iOS 原生网络与资源缓存上限
   */
  public setNativeCacheLimit(limitMB: number) {
    if (!this.isIOS) return;
    this.postMessage('setNativeCacheLimit', { limitMB });
  }

  /**
   * 处理来自 iOS 原生锁屏/AirPods/Apple Watch 的远程命令
   */
  private async dispatchRemoteCommand(command: string, arg?: any) {
    try {
      const { usePlayerStore } = await import('@/store/modules/player');
      const { usePlaylistStore } = await import('@/store/modules/playlist');
      const { audioService } = await import('@/services/audioService');
      const playerStore = usePlayerStore();
      const playlistStore = usePlaylistStore();

      switch (command) {
        case 'play':
          if (audioService.getCurrentSound()?.src) {
            audioService.resume();
            playerStore.setIsPlay(true);
            playerStore.userPlayIntent = true;
          } else if (playerStore.playMusic?.id) {
            const { playTrack } = await import('@/services/playbackController');
            await playTrack(playerStore.playMusic, true);
          }
          break;
        case 'pause':
          audioService.pause();
          playerStore.setIsPlay(false);
          playerStore.userPlayIntent = false;
          break;
        case 'togglePlayPause':
          if (playerStore.play) {
            audioService.pause();
            playerStore.setIsPlay(false);
            playerStore.userPlayIntent = false;
          } else {
            if (audioService.getCurrentSound()?.src) {
              audioService.resume();
              playerStore.setIsPlay(true);
              playerStore.userPlayIntent = true;
            } else if (playerStore.playMusic?.id) {
              const { playTrack } = await import('@/services/playbackController');
              await playTrack(playerStore.playMusic, true);
            }
          }
          break;
        case 'nextTrack':
          playlistStore.nextPlay();
          break;
        case 'previousTrack':
          playlistStore.prevPlay();
          break;
        case 'changePlaybackPosition':
          if (typeof arg === 'number') {
            audioService.seek(arg);
          }
          break;
        default:
          console.log('[NativeBridge] Unknown remote command:', command);
      }
    } catch (err) {
      console.error('[NativeBridge] Error handling remote command:', err);
    }
  }
}

export const nativeBridge = new NativeBridge();
