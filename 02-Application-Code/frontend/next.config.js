/** @type {import('next').NextConfig} */

// INTERNAL_API_URL is read at SERVER RUNTIME (not build time).
// It is set as a K8s env var from the ecommerce-config ConfigMap.
// The browser never sees this URL — Next.js proxies /api/* calls
// server-side to the internal ALB. This breaks the build-time
// dependency on the internal ALB DNS.
//
// Flow:
//   Browser → GET /api/users/health
//   Next.js server rewrites → GET http://<internal-alb>/api/users/health
//   Response returned to browser
//
// This means the same Docker image works in ALL environments
// (dev, prod, DR) without rebuilding.

const INTERNAL_API_URL = process.env.INTERNAL_API_URL || 'http://localhost';

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',

  // Proxy all /api/* calls to the internal ALB at server runtime
  async rewrites() {
    return [
      {
        source: '/api/:path*',
        destination: `${INTERNAL_API_URL}/api/:path*`,
      },
    ];
  },
};

module.exports = nextConfig;
