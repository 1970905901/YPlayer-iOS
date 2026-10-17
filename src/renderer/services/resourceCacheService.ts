import { musicDB } from '@/hooks/MusicHook';
import { nativeBridge } from '@/services/nativeBridge';
import { useSettingsStore } from '@/store';
import { isElectron } from '@/utils';

export type CacheLimitType = '128mb' | '256mb' | '512mb' | '1gb' | '2gb' | 'unlimited' | 'none';

export interface CacheLimitOption {
  labelKey: string;
  value: CacheLimitType;
  bytes: number; // in bytes; -1 for unlimited, 0 for none
  mb: number;
}

export const CACHE_LIMIT_OPTIONS: CacheLimitOption[] = [
  { labelKey: 'player.settings.limits.128mb', value: '128mb', bytes: 128 * 1024 * 1024, mb: 128 },
  { labelKey: 'player.settings.limits.256mb', value: '256mb', bytes: 256 * 1024 * 1024, mb: 256 },
  { labelKey: 'player.settings.limits.512mb', value: '512mb', bytes: 512 * 1024 * 1024, mb: 512 },
  { labelKey: 'player.settings.limits.1gb', value: '1gb', bytes: 1024 * 1024 * 1024, mb: 1024 },
  { labelKey: 'player.settings.limits.2gb', value: '2gb', bytes: 2048 * 1024 * 1024, mb: 2048 },
  { labelKey: 'player.settings.limits.unlimited', value: 'unlimited', bytes: -1, mb: -1 },
  { labelKey: 'player.settings.limits.none', value: 'none', bytes: 0, mb: 0 }
];

export interface ResourceCacheEntry {
  key: string;
  resourceId: string;
  type: 'cover' | 'audio' | 'lyric' | 'api' | 'other';
  size: number;
  lastAccess: number;
  createdAt: number;
}

const CACHE_STORAGE_NAME = 'alger-resource-cache';
const META_DB_NAME = 'alger_resource_cache_meta';
const META_STORE_NAME = 'resource_entries';

class ResourceCacheService {
  private dbPromise: Promise<IDBDatabase> | null = null;
  private isPruning = false;

  constructor() {
    if (typeof window !== 'undefined') {
      this.initMetaDB().catch((err) => {
        console.warn('[ResourceCacheService] Meta DB 初始化提示:', err);
      });
    }
  }

  private initMetaDB(): Promise<IDBDatabase> {
    if (this.dbPromise) return this.dbPromise;

    this.dbPromise = new Promise((resolve, reject) => {
      if (typeof indexedDB === 'undefined') {
        reject(new Error('IndexedDB 不可用'));
        return;
      }
      const request = indexedDB.open(META_DB_NAME, 1);
      request.onupgradeneeded = (event: any) => {
        const db = event.target.result;
        if (!db.objectStoreNames.contains(META_STORE_NAME)) {
          const store = db.createObjectStore(META_STORE_NAME, { keyPath: 'key' });
          store.createIndex('resourceId', 'resourceId', { unique: false });
          store.createIndex('lastAccess', 'lastAccess', { unique: false });
          store.createIndex('type', 'type', { unique: false });
        }
      };
      request.onsuccess = (event: any) => resolve(event.target.result);
      request.onerror = (event: any) => reject(event.target.error);
    });

    return this.dbPromise;
  }

  /**
   * 获取当前配置的资源缓存上限
   */
  public getCacheLimit(): CacheLimitType {
    try {
      const settingsStore = useSettingsStore();
      const val = settingsStore.setData?.resourceCacheLimit;
      if (val && CACHE_LIMIT_OPTIONS.some((opt) => opt.value === val)) {
        return val as CacheLimitType;
      }
    } catch {
      // ignore
    }
    const local = localStorage.getItem('app_resource_cache_limit');
    if (local && CACHE_LIMIT_OPTIONS.some((opt) => opt.value === local)) {
      return local as CacheLimitType;
    }
    return '512mb';
  }

  /**
   * 获取当前上限对应的字节大小 (-1 代表无限制，0 代表不缓存)
   */
  public getLimitBytes(limit?: CacheLimitType): number {
    const cur = limit || this.getCacheLimit();
    const opt = CACHE_LIMIT_OPTIONS.find((item) => item.value === cur);
    return opt ? opt.bytes : 512 * 1024 * 1024;
  }

  /**
   * 设置资源缓存上限，并同步至各端（Electron / iOS / Web）
   */
  public async setCacheLimit(limit: CacheLimitType): Promise<void> {
    try {
      const settingsStore = useSettingsStore();
      settingsStore.setSetData({ resourceCacheLimit: limit });
    } catch (e) {
      console.warn('[ResourceCacheService] 更新设置存储失败:', e);
    }
    localStorage.setItem('app_resource_cache_limit', limit);

    const option = CACHE_LIMIT_OPTIONS.find((opt) => opt.value === limit);
    const mb = option ? option.mb : 512;

    // 1. 同步 Electron 磁盘缓存配置
    if (isElectron && window.electron?.ipcRenderer) {
      try {
        if (limit === 'none') {
          await window.electron.ipcRenderer.invoke('set-disk-cache-config', {
            enabled: false
          });
          await window.electron.ipcRenderer.invoke('clear-disk-cache', 'all');
        } else {
          const maxSizeMB = limit === 'unlimited' ? 102400 : mb;
          await window.electron.ipcRenderer.invoke('set-disk-cache-config', {
            enabled: true,
            maxSizeMB,
            cleanupPolicy: 'lru'
          });
        }
      } catch (err) {
        console.warn('[ResourceCacheService] 同步 Electron 磁盘缓存配置失败:', err);
      }
    }

    // 2. 同步 iOS 原生 URLCache 与封面缓存
    if (nativeBridge.isIOS) {
      try {
        if (limit === 'none') {
          nativeBridge.clearNativeCache();
          nativeBridge.setNativeCacheLimit(0);
        } else {
          nativeBridge.setNativeCacheLimit(limit === 'unlimited' ? 2048 : mb);
        }
      } catch (err) {
        console.warn('[ResourceCacheService] 同步 iOS 原生缓存配置失败:', err);
      }
    }

    // 3. 针对“不缓存”策略，立即清理现有所有缓存
    if (limit === 'none') {
      await this.clearAllCache();
      return;
    }

    // 4. 超出上限时自动触发清理
    await this.checkAndAutoPrune();
  }

  /**
   * 记录资源访问或新增资源缓存
   * 核心实现：“自动清理同一个资源的旧缓存” 与 “超限后自动清理”
   */
  public async trackResource(
    resourceId: string,
    url: string,
    size: number = 0,
    type: 'cover' | 'audio' | 'lyric' | 'api' | 'other' = 'other'
  ): Promise<void> {
    if (!resourceId || !url) return;

    // 如果处于“不缓存”模式，跳过缓存记录
    if (this.getCacheLimit() === 'none') return;

    try {
      const db = await this.initMetaDB();
      const tx = db.transaction(META_STORE_NAME, 'readwrite');
      const store = tx.objectStore(META_STORE_NAME);
      const index = store.index('resourceId');

      // 1. 自动清理同一个资源的旧缓存（防止同一首歌因 URL 或音质/参数变化导致旧文件堆积）
      const findOldRequest = index.getAll(resourceId);
      findOldRequest.onsuccess = async () => {
        const oldEntries = (findOldRequest.result as ResourceCacheEntry[]) || [];
        for (const oldEntry of oldEntries) {
          if (oldEntry.key !== url) {
            // 从 CacheStorage 移除旧请求
            if (typeof window !== 'undefined' && 'caches' in window) {
              try {
                const cache = await window.caches.open(CACHE_STORAGE_NAME);
                await cache.delete(oldEntry.key);
              } catch {
                // ignore
              }
            }
            // 从元数据移除旧记录
            try {
              const deleteTx = db.transaction(META_STORE_NAME, 'readwrite');
              deleteTx.objectStore(META_STORE_NAME).delete(oldEntry.key);
            } catch {
              // ignore
            }
          }
        }
      };

      // 2. 写入或更新当前资源的缓存元数据
      const estimatedSize = size > 0 ? size : this.estimateSizeByUrl(url, type);
      const newEntry: ResourceCacheEntry = {
        key: url,
        resourceId,
        type,
        size: estimatedSize,
        lastAccess: Date.now(),
        createdAt: Date.now()
      };
      store.put(newEntry);

      // 3. 异步检查并自动清理超出限制的旧资源
      tx.oncomplete = () => {
        void this.checkAndAutoPrune();
      };
    } catch (err) {
      console.warn('[ResourceCacheService] trackResource 出错:', err);
    }
  }

  /**
   * 检查总资源大小并在超出 128MB / 256MB / 512MB / 1GB / 2GB 时自动清理旧缓存
   */
  public async checkAndAutoPrune(): Promise<void> {
    if (this.isPruning) return;
    const limitBytes = this.getLimitBytes();

    // “无限制”或“不缓存”不需要执行 LRU 容量削减
    if (limitBytes <= 0 || limitBytes === Infinity) return;

    this.isPruning = true;
    try {
      const db = await this.initMetaDB();
      const tx = db.transaction(META_STORE_NAME, 'readonly');
      const store = tx.objectStore(META_STORE_NAME);
      const getAllReq = store.getAll();

      getAllReq.onsuccess = async () => {
        try {
          const entries = (getAllReq.result as ResourceCacheEntry[]) || [];
          let totalBytes = entries.reduce((sum, item) => sum + (item.size || 0), 0);

          if (totalBytes <= limitBytes) {
            this.isPruning = false;
            return;
          }

          // 按最近访问时间升序排列（最旧的在最前，LRU 策略）
          entries.sort((a, b) => a.lastAccess - b.lastAccess);

          // 设定清理目标为上限的 85%，预留 15% 缓冲区间，防止每次加载新资源都频繁触发小额清理
          const targetBytes = limitBytes * 0.85;
          let cacheStorage: Cache | null = null;
          if (typeof window !== 'undefined' && 'caches' in window) {
            try {
              cacheStorage = await window.caches.open(CACHE_STORAGE_NAME);
            } catch {
              cacheStorage = null;
            }
          }

          const deleteTx = db.transaction(META_STORE_NAME, 'readwrite');
          const deleteStore = deleteTx.objectStore(META_STORE_NAME);

          for (const entry of entries) {
            if (totalBytes <= targetBytes) break;

            if (cacheStorage) {
              await cacheStorage.delete(entry.key);
            }
            deleteStore.delete(entry.key);
            totalBytes -= entry.size || 0;
          }
        } finally {
          this.isPruning = false;
        }
      };

      getAllReq.onerror = () => {
        this.isPruning = false;
      };
    } catch {
      this.isPruning = false;
    }
  }

  /**
   * 获取当前软件所有加载资源的总缓存大小及统计
   */
  public async getCacheUsage(): Promise<{
    usedBytes: number;
    formattedUsed: string;
    limitBytes: number;
    formattedLimit: string;
  }> {
    let usedBytes = 0;

    // 1. 计算 Web CacheStorage 与 IndexedDB 元数据大小
    try {
      const db = await this.initMetaDB();
      const tx = db.transaction(META_STORE_NAME, 'readonly');
      const store = tx.objectStore(META_STORE_NAME);
      const entries = await new Promise<ResourceCacheEntry[]>((resolve) => {
        const req = store.getAll();
        req.onsuccess = () => resolve(req.result || []);
        req.onerror = () => resolve([]);
      });
      usedBytes += entries.reduce((sum, item) => sum + (item.size || 0), 0);
    } catch {
      // ignore
    }

    // 2. 结合 W3C StorageManager 真实统计
    if (typeof navigator !== 'undefined' && navigator.storage?.estimate) {
      try {
        const estimate = await navigator.storage.estimate();
        if (estimate.usage && estimate.usage > usedBytes) {
          usedBytes = estimate.usage;
        }
      } catch {
        // ignore
      }
    }

    // 3. 若为 Electron 环境，整合磁盘缓存统计
    if (isElectron && window.electron?.ipcRenderer) {
      try {
        const stats = await window.electron.ipcRenderer.invoke('get-disk-cache-stats');
        if (stats?.totalSizeBytes) {
          usedBytes = Math.max(usedBytes, stats.totalSizeBytes);
        }
      } catch {
        // ignore
      }
    }

    const limitBytes = this.getLimitBytes();
    const curLimit = this.getCacheLimit();
    let formattedLimit = '';
    if (curLimit === 'unlimited') {
      formattedLimit = '无限制';
    } else if (curLimit === 'none') {
      formattedLimit = '不缓存';
    } else {
      formattedLimit = this.formatBytes(limitBytes);
    }

    return {
      usedBytes,
      formattedUsed: this.formatBytes(usedBytes),
      limitBytes,
      formattedLimit
    };
  }

  /**
   * 彻底清空整个软件的所有加载资源缓存
   */
  public async clearAllCache(): Promise<void> {
    // 1. 清空 CacheStorage
    if (typeof window !== 'undefined' && 'caches' in window) {
      try {
        const cacheNames = await window.caches.keys();
        for (const name of cacheNames) {
          await window.caches.delete(name);
        }
      } catch (e) {
        console.warn('[ResourceCacheService] 清理 CacheStorage 异常:', e);
      }
    }

    // 2. 清空缓存元数据库
    try {
      const db = await this.initMetaDB();
      const tx = db.transaction(META_STORE_NAME, 'readwrite');
      tx.objectStore(META_STORE_NAME).clear();
    } catch (e) {
      console.warn('[ResourceCacheService] 清理 Meta DB 异常:', e);
    }

    // 3. 清空 musicDB 瞬时请求与解析缓存表
    try {
      await musicDB.clearStore('api_cache');
      await musicDB.clearStore('music_url_cache');
    } catch {
      // ignore
    }

    // 4. 清空 Electron 磁盘音频与歌词缓存
    if (isElectron && window.electron?.ipcRenderer) {
      try {
        await window.electron.ipcRenderer.invoke('clear-disk-cache', 'all');
      } catch (e) {
        console.warn('[ResourceCacheService] 清理 Electron 磁盘缓存异常:', e);
      }
    }

    // 5. 清空 iOS 原生网络与锁屏封面缓存
    if (nativeBridge.isIOS) {
      try {
        nativeBridge.clearNativeCache();
      } catch (e) {
        console.warn('[ResourceCacheService] 清理 iOS 原生缓存异常:', e);
      }
    }
  }

  /**
   * 辅助方法：格式化字节大小
   */
  public formatBytes(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
    const val = bytes / Math.pow(1024, i);
    return `${val < 10 && i > 0 ? val.toFixed(2) : val.toFixed(1)} ${units[i]}`;
  }

  /**
   * 辅助方法：根据资源类型和 URL 估算初始大小
   */
  private estimateSizeByUrl(url: string, type: string): number {
    if (type === 'cover' || /param=\d+y\d+/i.test(url)) {
      return 180 * 1024; // 封面图约 180KB
    }
    if (type === 'audio' || /\.(mp3|flac|m4a|aac|ogg|wav)/i.test(url)) {
      return 15 * 1024 * 1024; // 音频文件约 15MB
    }
    if (type === 'lyric') {
      return 8 * 1024; // 歌词文本约 8KB
    }
    return 32 * 1024; // API 或其他数据约 32KB
  }
}

export const resourceCacheService = new ResourceCacheService();
