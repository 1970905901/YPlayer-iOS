import { defineStore } from 'pinia';
import { ref } from 'vue';

import { getLikedList, likeSong } from '@/api/music';
import { hasPermission } from '@/utils/auth';
import { getLocalStorageItem, isBilibiliIdMatch, setLocalStorageItem } from '@/utils/playerUtils';

/**
 * 收藏管理 Store
 * 负责：收藏列表、不喜欢列表的管理
 */
export const useFavoriteStore = defineStore('favorite', () => {
  // ==================== 状态 ====================
  const favoriteList = ref<Array<number | string>>(getLocalStorageItem('favoriteList', []));
  const dislikeList = ref<Array<number | string>>(getLocalStorageItem('dislikeList', []));

  // ==================== Actions ====================

  /**
   * 添加到收藏列表
   */
  const addToFavorite = async (id: number | string) => {
    if (id === undefined || id === null || id === '') return;

    // 检查是否已存在
    const isAlreadyInList = favoriteList.value.some((existingId) =>
      typeof id === 'string' && id.includes('--')
        ? isBilibiliIdMatch(existingId, id)
        : String(existingId) === String(id)
    );

    if (!isAlreadyInList) {
      favoriteList.value.unshift(id);
      setLocalStorageItem('favoriteList', favoriteList.value);
    }

    // 只要是有效网易云歌曲ID且用户已登录有token，就调用网易云云端收藏API
    const numericId = typeof id === 'number' ? id : parseInt(String(id), 10);
    if (!isNaN(numericId) && numericId > 0 && !String(id).includes('--')) {
      const token = localStorage.getItem('token');
      const { useUserStore } = await import('./user');
      const userStore = useUserStore();

      if (userStore.user && token) {
        try {
          const res = await likeSong(numericId, true);
          if (res.data?.code !== 200 && res.data?.code !== undefined) {
            console.warn('收藏歌曲API返回非200状态:', res.data);
          }
        } catch (error) {
          console.error('收藏歌曲API调用失败:', error);
        }
      }
    }
  };

  /**
   * 从收藏列表移除
   */
  const removeFromFavorite = async (id: number | string) => {
    if (id === undefined || id === null || id === '') return;

    // 对于B站视频，需要根据bvid和cid来匹配
    if (typeof id === 'string' && id.includes('--')) {
      favoriteList.value = favoriteList.value.filter(
        (existingId) => !isBilibiliIdMatch(existingId, id)
      );
    } else {
      favoriteList.value = favoriteList.value.filter(
        (existingId) => String(existingId) !== String(id)
      );

      // 只要是有效网易云歌曲ID且用户已登录有token，就调用网易云云端取消收藏API
      const numericId = typeof id === 'number' ? id : parseInt(String(id), 10);
      if (!isNaN(numericId) && numericId > 0 && !String(id).includes('--')) {
        const token = localStorage.getItem('token');
        const { useUserStore } = await import('./user');
        const userStore = useUserStore();

        if (userStore.user && token) {
          try {
            const res = await likeSong(numericId, false);
            if (res.data?.code !== 200 && res.data?.code !== undefined) {
              console.warn('取消收藏歌曲API返回非200状态:', res.data);
            }
          } catch (error) {
            console.error('取消收藏歌曲API调用失败:', error);
          }
        }
      }
    }
    setLocalStorageItem('favoriteList', favoriteList.value);
  };

  /**
   * 添加到不喜欢列表
   */
  const addToDislikeList = (id: number | string) => {
    if (!dislikeList.value.some((existingId) => String(existingId) === String(id))) {
      dislikeList.value.push(id);
      setLocalStorageItem('dislikeList', dislikeList.value);
    }
  };

  /**
   * 从不喜欢列表移除
   */
  const removeFromDislikeList = (id: number | string) => {
    dislikeList.value = dislikeList.value.filter((existingId) => String(existingId) !== String(id));
    setLocalStorageItem('dislikeList', dislikeList.value);
  };

  /**
   * 初始化收藏列表（从服务器同步）
   */
  const initializeFavoriteList = async () => {
    const { useUserStore } = await import('./user');
    const userStore = useUserStore();
    const localFavoriteList = localStorage.getItem('favoriteList');
    const localList: Array<number | string> = localFavoriteList ? JSON.parse(localFavoriteList) : [];

    let synced = false;

    if (userStore.user && userStore.user.userId) {
      // 1. 优先尝试通过 /likelist 获取全部喜欢的歌曲ID
      try {
        const res = await getLikedList(userStore.user.userId);
        if (res.data?.ids && Array.isArray(res.data.ids) && res.data.ids.length > 0) {
          const serverList: number[] = [...res.data.ids].reverse();
          const nonNcmLocal = localList.filter(
            (id) => typeof id === 'string' && id.includes('--')
          );
          favoriteList.value = Array.from(new Set([...serverList, ...nonNcmLocal]));
          synced = true;
          console.log(`[Favorite] 已从网易云 likelist 同步 ${serverList.length} 首收藏歌曲`);
        }
      } catch (error) {
        console.warn('[Favorite] 获取网易云 likelist 失败，尝试备用方案:', error);
      }

      // 2. 如果 likelist 获取失败或为空（如 UID 登录只读模式），从用户默认歌单“我喜欢的音乐”提取 trackIds
      if (!synced) {
        try {
          const { getUserPlaylist } = await import('@/api/user');
          const { getPlayListDetail } = await import('@/api/music');
          const playlistRes = await getUserPlaylist(userStore.user.userId, 50, 0);
          const playlists = playlistRes.data?.playlist || [];
          const favPlaylist =
            playlists.find((p: any) => p.specialType === 5) || playlists[0];
          if (favPlaylist?.id) {
            const detailRes = await getPlayListDetail(favPlaylist.id);
            const trackIds = detailRes.data?.playlist?.trackIds;
            if (Array.isArray(trackIds) && trackIds.length > 0) {
              const serverList: number[] = trackIds.map((t: any) => t.id);
              const nonNcmLocal = localList.filter(
                (id) => typeof id === 'string' && id.includes('--')
              );
              favoriteList.value = Array.from(new Set([...serverList, ...nonNcmLocal]));
              synced = true;
              console.log(
                `[Favorite] 已从网易云用户歌单(${favPlaylist.name})同步 ${serverList.length} 首歌曲`
              );
            }
          }
        } catch (err) {
          console.warn('[Favorite] 从歌单同步收藏列表失败:', err);
        }
      }
    }

    if (!synced) {
      favoriteList.value = localList;
    }

    setLocalStorageItem('favoriteList', favoriteList.value);
  };

  /**
   * 检查歌曲是否已收藏
   */
  const isFavorite = (id: number | string): boolean => {
    if (id === undefined || id === null || id === '') return false;
    return favoriteList.value.some((existingId) =>
      typeof id === 'string' && id.includes('--')
        ? isBilibiliIdMatch(existingId, id)
        : String(existingId) === String(id)
    );
  };

  /**
   * 检查歌曲是否在不喜欢列表中
   */
  const isDisliked = (id: number | string): boolean => {
    if (id === undefined || id === null || id === '') return false;
    return dislikeList.value.some((existingId) => String(existingId) === String(id));
  };

  return {
    // 状态
    favoriteList,
    dislikeList,

    // Actions
    addToFavorite,
    removeFromFavorite,
    addToDislikeList,
    removeFromDislikeList,
    initializeFavoriteList,
    isFavorite,
    isDisliked
  };
});
