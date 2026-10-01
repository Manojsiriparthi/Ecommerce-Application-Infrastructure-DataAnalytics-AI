import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import jwt from 'jsonwebtoken';
import { PrismaClient } from '@prisma/client';
import Redis from 'ioredis';

const app = express();
const prisma = new PrismaClient();
const port = Number(process.env.PORT || 4003);
const secret = process.env.JWT_SECRET || 'dev-secret';

app.use(helmet());
app.use(cors());
app.use(express.json());

// =============================================================================
// Redis cache (cache-aside pattern)
// =============================================================================
// WHY: the cart is read on nearly every page view. Hitting Aurora each time
// makes the DB the bottleneck. We cache each user's cart in Redis and serve
// reads from memory; we invalidate the cache on any write. Aurora stays the
// source of truth; Redis just absorbs the hot reads.
//
// CONNECTION: host/port/auth come from env, injected by the K8s deployment:
//   REDIS_HOST       <- ConfigMap ecommerce-config/redis_host
//   REDIS_PORT       <- "6379"
//   REDIS_AUTH_TOKEN <- Secret redis-secrets/auth_token (from Secrets Manager
//                       via the Secrets Store CSI driver)
// TLS is enabled because ElastiCache is configured with in-transit encryption.
//
// RESILIENCE: if Redis is unreachable (e.g. cross-region during DR), we must
// NOT break the cart. Every cache call is wrapped so a Redis failure falls back
// to the database. lazyConnect + a short retry keeps startup clean.
// =============================================================================
const CART_TTL_SECONDS = 60 * 60 * 24; // 24h — matches a typical active-cart window
const redisEnabled = Boolean(process.env.REDIS_HOST && process.env.REDIS_HOST !== 'placeholder');

const redis = redisEnabled
  ? new Redis({
      host: process.env.REDIS_HOST,
      port: Number(process.env.REDIS_PORT || 6379),
      password: process.env.REDIS_AUTH_TOKEN || undefined,
      tls: {}, // ElastiCache in-transit encryption
      lazyConnect: true,
      maxRetriesPerRequest: 1,
      retryStrategy: (times) => (times > 3 ? null : Math.min(times * 200, 1000)),
    })
  : null;

if (redis) {
  redis.connect().catch((e) => console.error('[redis] initial connect failed:', e.message));
  redis.on('error', (e) => console.error('[redis] error:', e.message));
  redis.on('connect', () => console.log('[redis] connected'));
}

const cartKey = (userId: string) => `cart:${userId}`;

// Read cart from cache; returns null on miss or any Redis error (safe fallback).
async function getCachedCart(userId: string): Promise<any[] | null> {
  if (!redis) return null;
  try {
    const cached = await redis.get(cartKey(userId));
    return cached ? JSON.parse(cached) : null;
  } catch (e: any) {
    console.error('[redis] get failed, falling back to DB:', e.message);
    return null;
  }
}

// Write cart to cache (best-effort; never throws into the request path).
async function setCachedCart(userId: string, items: any[]): Promise<void> {
  if (!redis) return;
  try {
    await redis.set(cartKey(userId), JSON.stringify(items), 'EX', CART_TTL_SECONDS);
  } catch (e: any) {
    console.error('[redis] set failed:', e.message);
  }
}

// Invalidate on any write so the next read repopulates from the DB.
async function invalidateCart(userId: string): Promise<void> {
  if (!redis) return;
  try {
    await redis.del(cartKey(userId));
  } catch (e: any) {
    console.error('[redis] del failed:', e.message);
  }
}

function auth(req: any, res: any, next: any) {
  try {
    const h = req.headers.authorization;
    if (!h?.startsWith('Bearer ')) return res.status(401).json({ message: 'Unauthorized' });
    req.user = jwt.verify(h.slice(7), secret);
    next();
  } catch {
    return res.status(401).json({ message: 'Invalid token' });
  }
}

app.get('/health', (_, r) => r.json({ service: 'cart-service', status: 'ok', redis: redisEnabled }));

// GET cart — cache-aside: try Redis first, fall back to DB on miss, then cache.
app.get('/api/cart', auth, async (req: any, res) => {
  const userId = req.user.sub;

  const cached = await getCachedCart(userId);
  if (cached) {
    return res.json({ items: cached, source: 'cache' });
  }

  const items = await prisma.cartItem.findMany({
    where: { userId },
    orderBy: { createdAt: 'desc' },
  });
  await setCachedCart(userId, items); // populate cache for next read
  res.json({ items, source: 'db' });
});

// All writes invalidate the cache so the next GET re-reads fresh from the DB.
app.post('/api/cart/items', auth, async (req: any, res) => {
  const { productId, quantity, unitPrice } = req.body;
  if (!productId || Number(quantity) < 1 || unitPrice === undefined)
    return res.status(400).json({ message: 'productId, quantity and unitPrice are required' });
  const item = await prisma.cartItem.upsert({
    where: { userId_productId: { userId: req.user.sub, productId } },
    update: { quantity: { increment: Number(quantity) }, unitPrice },
    create: { userId: req.user.sub, productId, quantity: Number(quantity), unitPrice },
  });
  await invalidateCart(req.user.sub);
  res.status(201).json({ item });
});

app.patch('/api/cart/items/:id', auth, async (req: any, res) => {
  const item = await prisma.cartItem.updateMany({
    where: { id: req.params.id, userId: req.user.sub },
    data: { quantity: Number(req.body.quantity) },
  });
  await invalidateCart(req.user.sub);
  res.json({ updated: item.count });
});

app.delete('/api/cart/items/:id', auth, async (req: any, res) => {
  await prisma.cartItem.deleteMany({ where: { id: req.params.id, userId: req.user.sub } });
  await invalidateCart(req.user.sub);
  res.status(204).send();
});

app.delete('/api/cart', auth, async (req: any, res) => {
  await prisma.cartItem.deleteMany({ where: { userId: req.user.sub } });
  await invalidateCart(req.user.sub);
  res.status(204).send();
});

app.listen(port, () => console.log(`cart-service listening on ${port}`));
