import request from '@/utils/request';

// 创建二维码key
//  /login/qr/key
export function getQrKey() {
  return request.get('/login/qr/key');
}

// 创建二维码
// /login/qr/create
export function createQr(key: any) {
  return request.get('/login/qr/create', { params: { key, qrimg: true } });
}

// 获取二维码状态
//  /login/qr/check
export function checkQr(key: any) {
  return request.get('/login/qr/check', { params: { key, noCookie: true } });
}

// 获取登录状态
// /login/status
export function getLoginStatus() {
  return request.get('/login/status');
}

// 获取用户信息
// /user/account
export async function getUserDetail() {
  const res = await request.get('/user/account');
  if (res?.data?.profile) {
    return res;
  }
  // 如果没有 profile 但有 account 信息，构造 profile 兜底
  if (res?.data?.account && !res?.data?.profile) {
    res.data.profile = {
      userId: res.data.account.id,
      nickname: res.data.account.userName || '用户',
      avatarUrl: res.data.account.avatarUrl || ''
    };
    return res;
  }
  // 兜底尝试 /login/status
  try {
    const statusRes = await request.get('/login/status');
    const statusProfile = statusRes?.data?.data?.profile || statusRes?.data?.profile;
    if (statusProfile) {
      if (!res.data) res.data = {};
      res.data.profile = statusProfile;
      return res;
    }
  } catch (err) {
    console.warn('获取 /login/status 兜底失败:', err);
  }
  return res;
}

// 退出登录
// /logout
export function logout() {
  return request.get('/logout');
}

// 手机号登录
// /login/cellphone
export function loginByCellphone(phone: string, password: string) {
  return request.post('/login/cellphone', {
    phone,
    password
  });
}

// UID登录 - 通过用户ID获取用户信息
// /user/detail
export function loginByUid(uid: string | number) {
  return request.get('/user/detail', {
    params: { uid }
  });
}
