FROM node:20-alpine AS deps

WORKDIR /app

COPY package*.json ./
RUN npm ci


FROM node:20-alpine AS builder

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

RUN npx prisma generate
RUN npm run build


FROM node:20-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=4005


# Security upgrade: update OpenSSL
RUN apk update \
    && apk upgrade openssl \
    && rm -rf /var/cache/apk/*

RUN addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 appuser

COPY --from=builder /app/package*.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/prisma ./prisma

RUN chown -R appuser:nodejs /app

USER appuser

EXPOSE 4005

CMD ["node", "dist/index.js"]
