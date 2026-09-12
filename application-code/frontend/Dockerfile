FROM node:20-alpine AS deps

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci


FROM node:20-alpine AS builder

WORKDIR /app

ARG NEXT_PUBLIC_USER_API
ARG NEXT_PUBLIC_PRODUCT_API
ARG NEXT_PUBLIC_CART_API
ARG NEXT_PUBLIC_ORDER_API
ARG NEXT_PUBLIC_PAYMENT_API

ENV NEXT_PUBLIC_USER_API=$NEXT_PUBLIC_USER_API
ENV NEXT_PUBLIC_PRODUCT_API=$NEXT_PUBLIC_PRODUCT_API
ENV NEXT_PUBLIC_CART_API=$NEXT_PUBLIC_CART_API
ENV NEXT_PUBLIC_ORDER_API=$NEXT_PUBLIC_ORDER_API
ENV NEXT_PUBLIC_PAYMENT_API=$NEXT_PUBLIC_PAYMENT_API

COPY --from=deps /app/node_modules ./node_modules

COPY . .

RUN npm run build


FROM node:20-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

RUN addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 nextjs

COPY --from=builder /app/public ./public

COPY --from=builder \
    --chown=nextjs:nodejs \
    /app/.next/standalone ./

COPY --from=builder \
    --chown=nextjs:nodejs \
    /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000

CMD ["node", "server.js"]
