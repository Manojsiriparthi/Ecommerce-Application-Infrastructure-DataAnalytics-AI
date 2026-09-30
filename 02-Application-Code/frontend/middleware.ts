import { NextRequest, NextResponse } from 'next/server';

// =============================================================================
// API Proxy Middleware
// =============================================================================
// WHY MIDDLEWARE NOT REWRITES:
//   Next.js rewrites() are evaluated at BUILD TIME and baked into the route
//   manifest. The INTERNAL_API_URL env var is only available at RUNTIME (pod
//   startup from K8s ConfigMap), so rewrites() always sees undefined → falls
//   back to http://localhost → ECONNREFUSED.
//
//   Middleware runs on EVERY REQUEST at runtime, so process.env.INTERNAL_API_URL
//   is always the live value injected by Kubernetes.
//
// FLOW:
//   Browser → GET /api/users/login
//   Middleware reads INTERNAL_API_URL from process.env at request time
//   Proxies → GET http://<internal-alb>/api/users/login
//   Returns response to browser
// =============================================================================

export async function middleware(request: NextRequest) {
  const { pathname, search } = request.nextUrl;

  // Only proxy /api/* routes
  if (!pathname.startsWith('/api/')) {
    return NextResponse.next();
  }

  // EXCEPTION: /api/region is a LOCAL frontend route (app/api/region/route.ts).
  // It reports which AWS region THIS pod runs in (DR failover visibility), so
  // it must NOT be proxied to the backend — let Next.js handle it locally.
  if (pathname === '/api/region') {
    return NextResponse.next();
  }

  const internalApiUrl = process.env.INTERNAL_API_URL;

  if (!internalApiUrl) {
    console.error('[middleware] INTERNAL_API_URL is not set — cannot proxy API calls');
    return NextResponse.json(
      { message: 'Service unavailable — backend URL not configured' },
      { status: 503 }
    );
  }

  // Build the upstream URL
  const upstreamUrl = `${internalApiUrl}${pathname}${search}`;

  // Forward the request to the internal ALB
  try {
    const upstreamResponse = await fetch(upstreamUrl, {
      method: request.method,
      headers: {
        'content-type': request.headers.get('content-type') || 'application/json',
        'authorization': request.headers.get('authorization') || '',
        'x-forwarded-for': request.headers.get('x-forwarded-for') || '',
      },
      body: ['GET', 'HEAD'].includes(request.method) ? undefined : await request.text(),
    });

    const responseBody = await upstreamResponse.text();

    return new NextResponse(responseBody, {
      status: upstreamResponse.status,
      headers: {
        'content-type': upstreamResponse.headers.get('content-type') || 'application/json',
      },
    });
  } catch (error) {
    console.error(`[middleware] Proxy error for ${upstreamUrl}:`, error);
    return NextResponse.json(
      { message: 'Unable to connect to the backend service' },
      { status: 502 }
    );
  }
}

export const config = {
  matcher: '/api/:path*',
};
