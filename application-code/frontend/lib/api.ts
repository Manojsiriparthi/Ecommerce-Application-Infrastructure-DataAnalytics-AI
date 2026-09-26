export const API = {
  user: process.env.NEXT_PUBLIC_USER_API || 'http://localhost:4001',
  product: process.env.NEXT_PUBLIC_PRODUCT_API || 'http://localhost:4002',
  cart: process.env.NEXT_PUBLIC_CART_API || 'http://localhost:4003',
  order: process.env.NEXT_PUBLIC_ORDER_API || 'http://localhost:4004',
  payment: process.env.NEXT_PUBLIC_PAYMENT_API || 'http://localhost:4005',
};

export function authHeaders(): Record<string, string> {
  const token =
    typeof window !== 'undefined'
      ? localStorage.getItem('token')
      : null;

  return token
    ? {
        Authorization: `Bearer ${token}`,
      }
    : {};
}

export async function apiFetch(
  url: string,
  init: RequestInit = {}
): Promise<Response> {
  const headers = new Headers(init.headers);

  headers.set('Content-Type', 'application/json');

  const auth = authHeaders();

  Object.entries(auth).forEach(([key, value]) => {
    headers.set(key, value);
  });

  return fetch(url, {
    ...init,
    headers,
  });
}
