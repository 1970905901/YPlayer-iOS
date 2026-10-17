import { ref } from 'vue';

// 定义表配置的泛型接口
export interface StoreConfig<T extends string> {
  name: T;
  keyPath?: string;
}

// 创建一个使用 IndexedDB 的组合函数
const useIndexedDB = <T extends string, S extends Record<T, Record<string, any>>>(
  dbName: string,
  stores: StoreConfig<T>[],
  version: number = 1
) => {
  const db = ref<IDBDatabase | null>(null);
  let initPromise: Promise<IDBDatabase> | null = null;

  // 打开数据库并创建表
  const initDB = () => {
    if (initPromise) return initPromise;
    initPromise = new Promise<IDBDatabase>((resolve, reject) => {
      try {
        const request = indexedDB.open(dbName, version);

        request.onupgradeneeded = (event: any) => {
          const dbInstance = event.target.result;
          stores.forEach((store) => {
            if (!dbInstance.objectStoreNames.contains(store.name)) {
              dbInstance.createObjectStore(store.name, {
                keyPath: store.keyPath || 'id',
                autoIncrement: true
              });
            }
          });
        };

        request.onsuccess = (event: any) => {
          db.value = event.target.result;
          resolve(event.target.result);
        };

        request.onerror = (event: any) => {
          reject(event.target.error);
        };
      } catch (e) {
        reject(e);
      }
    });
    return initPromise;
  };

  // 立即触发初始化（非阻塞，支持 iOS 14）
  if (typeof indexedDB !== 'undefined') {
    initDB().catch((err) => {
      console.warn('IndexedDB auto-init warning:', err);
    });
  }

  const getDB = async (): Promise<IDBDatabase> => {
    if (db.value) return db.value;
    return await initDB();
  };

  // 通用新增数据
  const addData = async <K extends T>(storeName: K, value: S[K]): Promise<void> => {
    const targetDb = await getDB();
    return new Promise<void>((resolve, reject) => {
      try {
        const tx = targetDb.transaction(storeName, 'readwrite');
        const store = tx.objectStore(storeName);

        const request = store.add(value);

        request.onsuccess = () => {
          resolve();
        };

        request.onerror = (event) => {
          console.error('新增失败:', (event.target as IDBRequest).error);
          reject((event.target as IDBRequest).error);
        };
      } catch (err) {
        reject(err);
      }
    });
  };

  // 通用保存数据（新增或更新）
  const saveData = async <K extends T>(storeName: K, value: S[K]): Promise<void> => {
    const targetDb = await getDB();
    return new Promise<void>((resolve, reject) => {
      try {
        const tx = targetDb.transaction(storeName, 'readwrite');
        const store = tx.objectStore(storeName);
        const request = store.put(value);

        request.onsuccess = () => {
          resolve();
        };

        request.onerror = (event) => {
          reject((event.target as IDBRequest).error);
        };
      } catch (err) {
        reject(err);
      }
    });
  };

  // 通用获取数据
  const getData = async <K extends T>(storeName: K, key: string | number): Promise<S[K]> => {
    const targetDb = await getDB();
    return new Promise<S[K]>((resolve, reject) => {
      try {
        const tx = targetDb.transaction(storeName, 'readonly');
        const store = tx.objectStore(storeName);
        const request = store.get(key);

        request.onsuccess = (event) => {
          if (event.target) {
            resolve((event.target as IDBRequest).result);
          } else {
            reject('事件目标为空');
          }
        };

        request.onerror = (event) => {
          reject((event.target as IDBRequest).error);
        };
      } catch (err) {
        reject(err);
      }
    });
  };

  // 删除数据
  const deleteData = async <K extends T>(storeName: K, key: string | number): Promise<void> => {
    const targetDb = await getDB();
    return new Promise<void>((resolve, reject) => {
      try {
        const tx = targetDb.transaction(storeName, 'readwrite');
        const store = tx.objectStore(storeName);
        const request = store.delete(key);

        request.onsuccess = () => {
          resolve();
        };

        request.onerror = (event) => {
          reject((event.target as IDBRequest).error);
        };
      } catch (err) {
        reject(err);
      }
    });
  };

  // 查询所有数据
  const getAllData = async <K extends T>(storeName: K): Promise<S[K][]> => {
    const targetDb = await getDB();
    return new Promise<S[K][]>((resolve, reject) => {
      try {
        const tx = targetDb.transaction(storeName, 'readonly');
        const store = tx.objectStore(storeName);
        const request = store.getAll();

        request.onsuccess = (event) => {
          if (event.target) {
            resolve((event.target as IDBRequest).result);
          } else {
            reject('事件目标为空');
          }
        };

        request.onerror = (event) => {
          reject((event.target as IDBRequest).error);
        };
      } catch (err) {
        reject(err);
      }
    });
  };

  // 分页查询数据
  const getDataWithPagination = async <K extends T>(
    storeName: K,
    page: number,
    pageSize: number
  ): Promise<S[K][]> => {
    const targetDb = await getDB();
    return new Promise<S[K][]>((resolve, reject) => {
      try {
        const tx = targetDb.transaction(storeName, 'readonly');
        const store = tx.objectStore(storeName);
        const request = store.openCursor();
        const results: S[K][] = [];
        let index = 0;
        const skip = (page - 1) * pageSize;

        request.onsuccess = (event: any) => {
          const cursor = event.target.result;
          if (!cursor) {
            resolve(results);
            return;
          }

          if (index >= skip && results.length < pageSize) {
            results.push(cursor.value);
          }

          index++;
          cursor.continue();
        };

        request.onerror = (event: any) => {
          reject(event.target.error);
        };
      } catch (err) {
        reject(err);
      }
    });
  };

  return {
    initDB,
    addData,
    saveData,
    getData,
    deleteData,
    getAllData,
    getDataWithPagination
  };
};

export default useIndexedDB;
