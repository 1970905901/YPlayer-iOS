// @ts-nocheck

export interface NativeHttpResponse {
  id: string;
  status: number;
  data: string;
  headers?: Record<string, string>;
  error?: string | null;
}

interface PendingHandler {
  resolve: (res: { status: number; data: string; headers?: Record<string, string> }) => void;
  reject: (err: any) => void;
  timer: any;
}

const pendingRequests = new Map<string, PendingHandler>();

if (typeof window !== 'undefined' && !(window as any).__nativeHttpInitialized) {
  (window as any).__nativeHttpInitialized = true;
  (window as any).__nativeHttpCallback = (resp: NativeHttpResponse) => {
    if (!resp || !resp.id) return;
    const handler = pendingRequests.get(resp.id);
    if (handler) {
      clearTimeout(handler.timer);
      pendingRequests.delete(resp.id);
      if (resp.error) {
        handler.reject(new Error(resp.error));
      } else {
        handler.resolve({
          status: resp.status || 200,
          data: resp.data,
          headers: resp.headers || {}
        });
      }
    }
  };
}

export const nativeHttpRequest = (options: {
  url: string;
  method?: string;
  headers?: Record<string, string>;
  data?: string;
  timeout?: number;
}): Promise<{ status: number; data: string; headers?: Record<string, string> }> => {
  return new Promise((resolve, reject) => {
    const id = 'req_' + Date.now() + '_' + Math.random().toString(36).slice(2, 9);
    const timeout = options.timeout || 20000;

    const timer = setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        reject(new Error(`Native HTTP request timeout after ${timeout}ms: ${options.url}`));
      }
    }, timeout);

    pendingRequests.set(id, { resolve, reject, timer });

    // iOS WKWebView Bridge
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.nativePlayer
    ) {
      window.webkit.messageHandlers.nativePlayer.postMessage({
        action: 'httpRequest',
        id,
        url: options.url,
        method: options.method || 'GET',
        headers: options.headers || {},
        data: options.data || ''
      });
      return;
    }

    // Browser development fallback (e.g. vite dev / preview)
    fetch(options.url, {
      method: options.method || 'GET',
      headers: options.headers,
      body: options.method?.toUpperCase() !== 'GET' ? options.data : undefined
    })
      .then(async (response) => {
        clearTimeout(timer);
        pendingRequests.delete(id);
        const text = await response.text();
        const headers: Record<string, string> = {};
        response.headers.forEach((v, k) => {
          headers[k.toLowerCase()] = v;
        });
        resolve({
          status: response.status,
          data: text,
          headers
        });
      })
      .catch((err) => {
        clearTimeout(timer);
        pendingRequests.delete(id);
        reject(err);
      });
  });
};
