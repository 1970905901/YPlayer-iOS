import { nativeBridge } from '@/services/nativeBridge';
import { playbackDiagnostics } from '@/services/playbackDiagnostics';

interface NativeAudioMetadata {
  title: string;
  artist: string;
  album: string;
  artworkUrl: string;
  duration?: number;
}

interface ListenerEntry {
  callback: EventListenerOrEventListenerObject;
  once: boolean;
}

/**
 * Minimal HTMLAudioElement-compatible adapter backed by native AVPlayer on iOS.
 * The rest of the player keeps its existing event-driven interface.
 */
export class NativeAudioElement {
  public src = '';
  public paused = true;
  public ended = false;
  public duration = NaN;
  public muted = false;
  public preload = 'auto';
  public readyState = 0;
  public error: { code: number; message: string } | null = null;

  private currentTimeValue = 0;
  private playbackRateValue = 1;
  private volumeValue = 1;
  private autoplay = false;
  private metadata: NativeAudioMetadata | null = null;
  private listeners = new Map<string, Set<ListenerEntry>>();
  private pendingPlay: {
    promise: Promise<void>;
    resolve: () => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  } | null = null;

  constructor() {
    nativeBridge.setNativeAudioEventHandler((event, payload) =>
      this.handleNativeEvent(event, payload)
    );
  }

  public get currentTime(): number {
    return this.currentTimeValue;
  }

  public set currentTime(value: number) {
    if (!Number.isFinite(value) || value < 0) return;
    this.currentTimeValue = value;
    if (this.src) {
      nativeBridge.nativeAudioSeek(value);
    }
  }

  public get currentSrc(): string {
    return this.src;
  }

  public get playbackRate(): number {
    return this.playbackRateValue;
  }

  public set playbackRate(value: number) {
    if (!Number.isFinite(value) || value <= 0) return;
    this.playbackRateValue = value;
    if (this.src) nativeBridge.nativeAudioSetRate(value);
  }

  public get volume(): number {
    return this.volumeValue;
  }

  public set volume(value: number) {
    if (!Number.isFinite(value)) return;
    this.volumeValue = Math.max(0, Math.min(1, value));
    if (this.src) nativeBridge.nativeAudioSetVolume(this.muted ? 0 : this.volumeValue);
  }

  public setMetadata(metadata: NativeAudioMetadata) {
    this.metadata = metadata;
    if (this.src) {
      nativeBridge.nativeAudioUpdateMetadata(metadata);
    }
  }

  public updateLyric(text: string) {
    nativeBridge.nativeAudioUpdateLyric(text);
  }

  public setAutoplay(value: boolean) {
    this.autoplay = value;
  }

  public load() {
    this.error = null;
    this.ended = false;
    this.paused = true;
    this.readyState = 0;
    this.duration = NaN;
    this.currentTimeValue = 0;

    if (!this.src) {
      nativeBridge.nativeAudioStop();
      return;
    }

    playbackDiagnostics.log('native-audio-load', {
      url: this.src,
      metadata: this.metadata,
      rate: this.playbackRate,
      volume: this.muted ? 0 : this.volume
    });

    nativeBridge.nativeAudioLoad({
      url: this.src,
      ...(this.metadata ?? {}),
      autoplay: this.autoplay,
      position: 0,
      rate: this.playbackRate,
      volume: this.muted ? 0 : this.volume
    });
  }

  public play(): Promise<void> {
    if (!this.src) {
      return Promise.reject(new Error('native-audio-no-source'));
    }
    if (this.pendingPlay) return this.pendingPlay.promise;
    if (!this.paused && !this.ended) return Promise.resolve();

    this.ended = false;
    let resolve!: () => void;
    let reject!: (error: Error) => void;
    const promise = new Promise<void>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    const timer = setTimeout(() => {
      this.rejectPendingPlay(new Error('native-audio-play-timeout'));
    }, 12000);
    this.pendingPlay = { promise, resolve, reject, timer };
    playbackDiagnostics.log('native-audio-play-request');
    nativeBridge.nativeAudioPlay();
    return promise;
  }

  public pause() {
    playbackDiagnostics.log('native-audio-pause-request');
    nativeBridge.nativeAudioPause();
    if (!this.paused) {
      this.paused = true;
      this.dispatch('pause');
    }
  }

  public stop() {
    nativeBridge.nativeAudioStop();
    this.paused = true;
    this.ended = false;
    this.readyState = 0;
    this.currentTimeValue = 0;
    this.duration = NaN;
  }

  public removeAttribute(name: string) {
    if (name.toLowerCase() === 'src') {
      this.src = '';
    }
  }

  public addEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions
  ) {
    if (!callback) return;
    const once = typeof options === 'object' && !!options.once;
    let entries = this.listeners.get(type);
    if (!entries) {
      entries = new Set<ListenerEntry>();
      this.listeners.set(type, entries);
    }
    entries.add({ callback, once });
  }

  public removeEventListener(type: string, callback: EventListenerOrEventListenerObject | null) {
    if (!callback) return;
    const entries = this.listeners.get(type);
    if (!entries) return;
    for (const entry of entries) {
      if (entry.callback === callback) entries.delete(entry);
    }
  }

  private dispatch(type: string) {
    const entries = this.listeners.get(type);
    if (!entries) return;
    const event = new Event(type);
    for (const entry of Array.from(entries)) {
      if (entry.once) entries.delete(entry);
      if (typeof entry.callback === 'function') {
        entry.callback(event);
      } else {
        entry.callback.handleEvent(event);
      }
    }
  }

  private resolvePendingPlay() {
    if (!this.pendingPlay) return;
    clearTimeout(this.pendingPlay.timer);
    const { resolve } = this.pendingPlay;
    this.pendingPlay = null;
    resolve();
  }

  private rejectPendingPlay(error: Error) {
    if (!this.pendingPlay) return;
    clearTimeout(this.pendingPlay.timer);
    const { reject } = this.pendingPlay;
    this.pendingPlay = null;
    reject(error);
  }

  private handleNativeEvent(event: string, payload: any = {}) {
    if (event !== 'timeupdate') {
      playbackDiagnostics.log('native-audio-event', { event, payload });
    }

    switch (event) {
      case 'loadedmetadata':
        this.duration = Number(payload.duration) || NaN;
        this.currentTimeValue = Number(payload.currentTime) || 0;
        this.readyState = 1;
        this.dispatch('loadedmetadata');
        this.dispatch('durationchange');
        break;
      case 'canplay':
        this.readyState = 3;
        this.dispatch('canplay');
        break;
      case 'play':
        this.paused = false;
        this.ended = false;
        this.resolvePendingPlay();
        this.dispatch('play');
        break;
      case 'pause':
        if (!this.paused) {
          this.paused = true;
          this.dispatch('pause');
        }
        break;
      case 'timeupdate':
        this.currentTimeValue = Number(payload.currentTime) || 0;
        if (Number.isFinite(Number(payload.duration)) && Number(payload.duration) > 0) {
          this.duration = Number(payload.duration);
        }
        this.dispatch('timeupdate');
        break;
      case 'durationchange':
        this.duration = Number(payload.duration) || this.duration;
        this.dispatch('durationchange');
        break;
      case 'seeked':
        this.currentTimeValue = Number(payload.currentTime) || 0;
        this.dispatch('seeked');
        this.dispatch('timeupdate');
        break;
      case 'ended':
        this.paused = true;
        this.ended = true;
        this.dispatch('ended');
        break;
      case 'waiting':
        this.readyState = 2;
        this.dispatch('waiting');
        break;
      case 'error':
        this.error = {
          code: Number(payload.code) || 4,
          message: String(payload.message || 'native-audio-error')
        };
        this.rejectPendingPlay(new Error(this.error.message));
        this.dispatch('error');
        break;
      default:
        break;
    }
  }
}
