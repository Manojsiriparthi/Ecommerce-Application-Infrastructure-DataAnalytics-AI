// =============================================================================
// API configuration — relative paths only
// =============================================================================
// WHY RELATIVE PATHS:
//   Previously used NEXT_PUBLIC_*_API env vars with full URLs
//   baked into the bundle at build time. This caused two problems:
//     1. Docker image had to be rebuilt every time the internal ALB DNS changed
//     2. Jenkins pipeline needed to know the internal ALB DNS before building
//
// THE FIX — Next.js rewrites in next.config.js:
//   Browser calls: /api/users/register  (relative — no domain)
//   Next.js server rewrites to: http://<internal-alb>/api/users/register
//   INTERNAL_API_URL is set as a K8s env var from the ConfigMap at pod startup
//
// RESULT:
//   - Same Docker image works in ALL environments
//   - No build-time dependency on internal ALB DNS
//   - Jenkins builds once, deploys anywhere
// =============================================================================

export const API = {
  user:    '/api/users',
  product: '/api/products',
  cart:    '/api/cart',
  order:   '/api/orders',
  payment: '/api/payments',
};

export function authHeaders(): Record<string, string> {
  const token =
    typeof window !== 'undefined'
      ? localStorage.getItem('token')
      : null;

  return token
    ? { Authorization: `Bearer ${token}` }
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

  return fetch(url, { ...init, headers });
}
