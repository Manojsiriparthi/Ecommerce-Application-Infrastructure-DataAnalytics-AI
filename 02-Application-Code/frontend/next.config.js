/** @type {import('next').NextConfig} */

// INTERNAL_API_URL is read at SERVER RUNTIME (not build time).
// It is set as a K8s env var from the ecommerce-config ConfigMap.
// The browser never sees this URL — Next.js proxies /api/* calls
// server-side to the internal ALB. This breaks the build-time
// dependency on the internal ALB DNS.
//
// Flow:
//   Browser → GET /api/users/login
//   Next.js server reads INTERNAL_API_URL from env at startup
//   Rewrites → GET http://<internal-alb>/api/users/login
//   Response returned to browser
//
// IMPORTANT: The env var is read INSIDE rewrites() so it is evaluated
// at server startup time (when the pod starts) not at build time.
// This means the same Docker image works in ALL environments.

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',

  async rewrites() {
    // Read at server startup — picks up the K8s env var injected by ConfigMap
    const internalApiUrl = process.env.INTERNAL_API_URL || 'http://localhost';
    console.log('[next.config] INTERNAL_API_URL =', internalApiUrl);
    return [
      {
        source: '/api/:path*',
        destination: `${internalApiUrl}/api/:path*`,
      },
    ];
  },
};

module.exports = nextConfig;
