// @ts-nocheck
import CryptoJS from 'crypto-js';
import * as encrypt from './crypto';
import { nativeHttpRequest } from './nativeHttp';

const DOMAIN = 'https://music.163.com';
const API_DOMAIN = 'https://interface.music.163.com';

const userAgentMap = {
  weapi: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0',
  linuxapi: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36',
  api: 'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)'
};

const characters = 'abcdefghijklmnopqrstuvwxyz';
const WNMCID = (() => {
  let res = '';
  for (let i = 0; i < 6; i++) {
    res += characters.charAt(Math.floor(Math.random() * characters.length));
  }
  return `${res}.${Date.now().toString()}.01.0`;
})();

const generateRequestId = () => {
  return `${Date.now()}_${Math.floor(Math.random() * 1000).toString().padStart(4, '0')}`;
};

const cookieObjToString = (cookie: Record<string, string>) => {
  return Object.keys(cookie)
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(cookie[k])}`)
    .join('; ');
};

const cookieToJson = (cookie: string) => {
  if (!cookie) return {};
  const res: Record<string, string> = {};
  cookie.split(';').forEach((pair) => {
    const idx = pair.indexOf('=');
    if (idx > -1) {
      const k = pair.slice(0, idx).trim();
      const v = pair.slice(idx + 1).trim();
      res[k] = decodeURIComponent(v);
    }
  });
  return res;
};

const processCookieObject = (cookie: any, uri: string) => {
  const _ntes_nuid = CryptoJS.lib.WordArray.random(32).toString();
  const processed = {
    ...cookie,
    __remember_me: 'true',
    ntes_kaola_ad: '1',
    _ntes_nuid: cookie?._ntes_nuid || _ntes_nuid,
    _ntes_nnid: cookie?._ntes_nnid || `${_ntes_nuid},${Date.now().toString()}`,
    WNMCID: cookie?.WNMCID || WNMCID,
    WEVNSM: cookie?.WEVNSM || '1.0.0',
    osver: cookie?.osver || '16.2',
    deviceId: cookie?.deviceId || 'YPlayer-iOS-' + _ntes_nuid.slice(0, 8),
    os: cookie?.os || 'iPhone OS',
    channel: cookie?.channel || 'distribution',
    appver: cookie?.appver || '9.0.90'
  };

  if (uri.indexOf('login') === -1) {
    processed['NMTID'] = CryptoJS.lib.WordArray.random(16).toString();
  }
  return processed;
};

export const ncmRequest = async (uri: string, data: any = {}, options: any = {}) => {
  const headers: Record<string, string> = {
    'Content-Type': 'application/x-www-form-urlencoded'
  };

  let cookie = options.cookie || {};
  if (typeof cookie === 'string') {
    cookie = cookieToJson(cookie);
  }
  const token = typeof localStorage !== 'undefined' ? localStorage.getItem('token') : null;
  if (token && typeof token === 'string') {
    const tokenObj = cookieToJson(token);
    cookie = { ...tokenObj, ...cookie };
  }

  cookie = processCookieObject(cookie, uri);
  headers['Cookie'] = cookieObjToString(cookie);

  let url = '';
  let encryptData: any = '';
  let crypto = options.crypto || 'eapi';

  if (!options.crypto) {
    crypto = 'eapi';
  }

  let csrfToken = cookie['__csrf'] || '';

  switch (crypto) {
    case 'weapi':
      headers['Referer'] = options.domain || DOMAIN;
      headers['User-Agent'] = options.ua || userAgentMap.weapi;
      if (!csrfToken) {
        csrfToken = CryptoJS.lib.WordArray.random(16).toString();
        cookie['__csrf'] = csrfToken;
        headers['Cookie'] = cookieObjToString(cookie);
      }
      data.csrf_token = csrfToken;
      encryptData = encrypt.weapi(data);
      url = (options.domain || DOMAIN) + '/weapi/' + uri.substr(5);
      break;

    case 'linuxapi':
      headers['User-Agent'] = options.ua || userAgentMap.linuxapi;
      encryptData = encrypt.linuxapi({
        method: 'POST',
        url: (options.domain || DOMAIN) + uri,
        params: data
      });
      url = (options.domain || DOMAIN) + '/api/linux/forward';
      break;

    case 'eapi':
    case 'api':
      const header = {
        osver: cookie.osver,
        deviceId: cookie.deviceId,
        os: cookie.os,
        appver: cookie.appver,
        versioncode: cookie.versioncode || '140',
        mobilename: cookie.mobilename || 'iPhone',
        buildver: cookie.buildver || Date.now().toString().substr(0, 10),
        resolution: cookie.resolution || '1920x1080',
        __csrf: csrfToken,
        channel: cookie.channel,
        requestId: generateRequestId()
      };
      if (cookie.MUSIC_U) header['MUSIC_U'] = cookie.MUSIC_U;
      if (cookie.MUSIC_A) header['MUSIC_A'] = cookie.MUSIC_A;

      headers['Cookie'] = cookieObjToString(header);
      headers['User-Agent'] = options.ua || userAgentMap.api;

      if (crypto === 'eapi') {
        data.header = header;
        encryptData = encrypt.eapi(uri, data);
        url = (options.domain || API_DOMAIN) + '/eapi/' + uri.substr(5);
      } else {
        url = (options.domain || API_DOMAIN) + uri;
        encryptData = data;
      }
      break;
    default:
      url = (options.domain || DOMAIN) + uri;
      encryptData = data;
      break;
  }

  const postBody = new URLSearchParams(encryptData).toString();

  const response = await nativeHttpRequest({
    url,
    method: 'POST',
    headers,
    data: postBody
  });

  let parsedBody: any = null;
  try {
    parsedBody = JSON.parse(response.data);
  } catch (_e) {
    parsedBody = response.data;
  }

  return {
    status: response.status || 200,
    body: parsedBody
  };
};
