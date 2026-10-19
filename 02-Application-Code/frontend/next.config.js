/** @type {import('next').NextConfig} */

// API proxying is handled by middleware.ts (NOT rewrites).
// WHY: Next.js rewrites() are evaluated at BUILD TIME — the destination
// URL is baked into .next/routes-manifest.json. INTERNAL_API_URL is only
// available at runtime (K8s ConfigMap env var), so rewrites() always saw
// undefined and fell back to http://localhost → ECONNREFUSED on login.
//
// middleware.ts reads process.env.INTERNAL_API_URL on EVERY REQUEST,
// so it always picks up the live value injected by Kubernetes.

const nextConfig = {
  output: 'standalone',
};

module.exports = nextConfig;
