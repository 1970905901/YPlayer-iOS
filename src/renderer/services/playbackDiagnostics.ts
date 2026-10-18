import config from '../../../package.json';

interface DiagnosticEntry {
  at: string;
  event: string;
  data?: unknown;
}

class PlaybackDiagnostics {
  private readonly maxEntries = 200;
  private entries: DiagnosticEntry[] = [];

  log(event: string, data?: unknown) {
    this.entries.push({
      at: new Date().toISOString(),
      event,
      data
    });
    if (this.entries.length > this.maxEntries) {
      this.entries.splice(0, this.entries.length - this.maxEntries);
    }
    console.info('[PlaybackDiagnostics]', event, data ?? '');
  }

  snapshot(): string {
    return JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        version: config.version,
        userAgent: navigator.userAgent,
        visibility: document.visibilityState,
        entries: this.entries
      },
      null,
      2
    );
  }
}

export const playbackDiagnostics = new PlaybackDiagnostics();
