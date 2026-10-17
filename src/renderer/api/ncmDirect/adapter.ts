// @ts-nocheck
import type { AxiosResponse, InternalAxiosRequestConfig } from 'axios';

import { ncmModules } from './generatedModules';
import { nativeHttpRequest } from './nativeHttp';
import { ncmRequest } from './ncmRequest';

export const directNcmAdapter = async (
  config: InternalAxiosRequestConfig
): Promise<AxiosResponse> => {
  let url = config.url || '';

  // 如果包含完整外链 (非 127.0.0.1 回环)，直接通过 nativeHttpRequest 隧道请求
  if (url.startsWith('http://') || url.startsWith('https://')) {
    if (!url.includes('127.0.0.1') && !url.includes('localhost')) {
      const response = await nativeHttpRequest({
        url,
        method: config.method?.toUpperCase() || 'GET',
        headers: (config.headers as any) || {},
        data: typeof config.data === 'string' ? config.data : JSON.stringify(config.data || {})
      });
      let responseData = response.data;
      try {
        responseData = JSON.parse(response.data);
      } catch {
        // Keep string
      }
      return {
        data: responseData,
        status: response.status || 200,
        statusText: 'OK',
        headers: {},
        config
      };
    }
    // 如果是 127.0.0.1，解析出 pathname
    try {
      const parsed = new URL(url);
      url = parsed.pathname + parsed.search;
    } catch {
      // ignore
    }
  }

  // 规范化路由路径
  let pathname = url.split('?')[0];
  if (!pathname.startsWith('/')) {
    pathname = '/' + pathname;
  }

  // 聚合 query 参数
  const query: Record<string, any> = {};

  if (url.includes('?')) {
    const searchPart = url.slice(url.indexOf('?') + 1);
    const searchParams = new URLSearchParams(searchPart);
    searchParams.forEach((v, k) => {
      query[k] = v;
    });
  }

  if (config.params) {
    Object.assign(query, config.params);
  }

  if (config.data) {
    if (typeof config.data === 'string') {
      try {
        Object.assign(query, JSON.parse(config.data));
      } catch {
        // form urlencoded string
        const bodyParams = new URLSearchParams(config.data);
        bodyParams.forEach((v, k) => {
          query[k] = v;
        });
      }
    } else if (typeof config.data === 'object') {
      Object.assign(query, config.data);
    }
  }

  const moduleFn = ncmModules[pathname];
  if (typeof moduleFn === 'function') {
    try {
      const result = await moduleFn(query, ncmRequest);
      return {
        data: result.body,
        status: result.status || 200,
        statusText: 'OK',
        headers: {},
        config
      };
    } catch (err: any) {
      console.error(`[NcmDirect] Module ${pathname} failed:`, err);
      return Promise.reject({
        message: err.message || 'Direct NetEase request failed',
        config,
        response: {
          status: 500,
          data: { code: 500, msg: err.message }
        }
      });
    }
  }

  console.warn(`[NcmDirect] No module found for route: ${pathname}, falling back`);
  return Promise.reject({
    message: `Module not found for ${pathname}`,
    config,
    response: {
      status: 404,
      data: { code: 404, msg: 'Not Found' }
    }
  });
};
