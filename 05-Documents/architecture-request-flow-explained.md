# Architecture & Request Flow — Explained Simply
## pip-project-ecommerce

This document follows a single user request from the browser all the way to the
database and back, explaining every component it passes through: what problem
each one solves, what we configured, and what the alternatives were.

![alt text](<WhatsApp Image 2026-09-29 at 00.13.52.jpeg>)
---

## The Full Journey of One Request

```
  User's Browser
       │  types https://pip-ecommerce.com
       ▼
  ┌─────────────┐
  │  Route53    │  1. DNS — turns the name into an IP
  └─────┬───────┘
        ▼
  ┌─────────────┐
  │  WAF        │  2. Firewall — blocks attacks
  └─────┬───────┘
        ▼
  ┌─────────────┐
  │ External ALB│  3. Front door — routes to frontend pods
  └─────┬───────┘
        ▼
  ┌─────────────┐
  │ Frontend    │  4. Next.js — serves the web page
  │ (Next.js)   │     proxies /api/* calls
  └─────┬───────┘
        ▼
  ┌─────────────┐
  │ Internal ALB│  5. Private router — sends /api/users → user-service
  └─────┬───────┘
        ▼
  ┌─────────────┐
  │ Backend pod │  6. user-service etc — the business logic
  └─────┬───────┘
        ▼
  ┌─────────────┐
  │ Aurora DB   │  7. Database — stores users, products, orders
  └─────────────┘
```

---

## 1. Route53 — DNS

### What problem it solves
A browser can't connect to "pip-ecommerce.com" directly — it needs an IP address.
Route53 is AWS's phone book: it maps the domain name to the ALB.

### What we made
- A **hosted zone** for `pip-ecommerce.com` — the container for all DNS records
- An **A record** (alias) — points `pip-ecommerce.com` → the External ALB
- A **www A record** — points `www.pip-ecommerce.com` → the same ALB
- **CNAME records** — for ACM certificate validation (proves we own the domain)
- **NS records** — the 4 AWS nameservers we pasted into Namecheap

### A record vs CNAME — the difference (this confuses everyone)
- **A record** = maps a name directly to an IP address. We use an ALIAS A record
  (an AWS special) so `pip-ecommerce.com` points to the ALB. Works for the root
  domain (apex).
- **CNAME record** = maps a name to ANOTHER name. Used for cert validation:
  `_acme-challenge.pip-ecommerce.com → some-aws-validation-string`.
  CNAME cannot be used on the root domain — that's why AWS invented alias A records.

### 🏫 Simple analogy — A record vs CNAME
Think of a school:
- **A record** = "Principal's office is Room 101." A NAME points straight to a
  LOCATION (IP). `pip-ecommerce.com → 52.x.x.x`.
- **CNAME** = "The Exam Cell is wherever the Principal's office is." A NAME points
  to ANOTHER NAME, not a location. `www → pip-ecommerce.com`. If the principal
  moves rooms, the exam-cell sign auto-updates because it just says "same as
  principal."
- **Why CNAME can't be on the apex (root):** The root domain also holds other
  critical records (like the SOA/NS "who runs this school" records). A CNAME says
  "I am 100% identical to another name" — which would erase those critical records.
  So AWS invented the ALIAS A record: behaves like a CNAME (auto-follows the ALB)
  but is technically an A record, so it's allowed on the root.

### How it's added
The ALB has no fixed IP (it changes). So we use an **alias** A record that points
to the ALB's DNS name + its zone ID (`Z35SXDOTRQ7X7K` for us-east-1). AWS resolves
it dynamically. In Terraform this is the `aws_route53_record.apex` resource.

### DR failover role
Route53 also does **health checks** — it pings the primary ALB every 30 seconds.
Two records exist for the same name:
- PRIMARY → us-east-1 ALB (with health check)
- SECONDARY → us-west-2 DR ALB (fallback)
When the primary health check fails 3 times (90s), Route53 stops returning the
primary IP and returns the DR IP instead. This is automatic failover.

---

## 2. WAF (Web Application Firewall)

### What problem it solves
The internet is hostile. Bots try SQL injection, XSS, and brute-force attacks.
WAF inspects every request BEFORE it reaches the app and blocks bad ones.

### What we made
A WAFv2 WebACL attached to the External ALB with AWS managed rule sets:
- SQL injection protection
- Cross-site scripting (XSS) protection
- Rate limiting (blocks IPs sending too many requests)
- Common vulnerability rules (OWASP)

### How it works here
WAF sits on the ALB. A request like `?id=1' OR '1'='1` (SQL injection) gets a
403 Forbidden and never reaches the app. Blocked requests are logged to S3 and
counted in a CloudWatch alarm (`waf-blocked-spike`).

### 🏨 Simple analogy — WAF
WAF is the **security guard at the hotel entrance**. Before anyone reaches the
lobby (your app), the guard checks them: no weapons (SQL injection), no fake IDs
(XSS), and nobody who keeps coming back 1000 times a minute (rate limiting). Bad
guests are turned away at the door (403), never reaching the rooms.

### Alternative approaches
- **No WAF** — cheaper but exposes the app to attacks. Rejected.
- **Third-party WAF (Cloudflare)** — good but adds another vendor + cost. AWS WAF
  integrates natively with the ALB, so we use it.

---

## 3. External ALB (Application Load Balancer)

### What problem it solves
You have multiple frontend pods across 3 nodes. Something must spread traffic
across them and know which pods are healthy. That's the ALB's job.

### What we made
An internet-facing ALB (created by the AWS Load Balancer Controller from the
Kubernetes Ingress `frontend/ingress.yaml`). It:
- Listens on port 80 (and 443 once the cert is ready)
- Routes `/` → frontend-service → frontend pods
- Health-checks pods and only sends traffic to healthy ones
- Lives in the PUBLIC subnets (has a public IP)

### Why "internet-facing" + public subnets
It must be reachable from the internet, so it needs public IPs. The pods it
routes to are in PRIVATE subnets — the ALB bridges public → private safely.

### 🏨 Simple analogy — ALB
The ALB is the **hotel receptionist**. Guests (requests) arrive at the front desk.
The receptionist knows which rooms (pods) are occupied and working, and sends each
guest to an available room. If a room's phone is broken (failed health check), the
receptionist stops sending guests there until it's fixed.

### How it connects to frontend
`target-type: ip` — the ALB registers pod IPs directly as targets (not node
ports). The public EKS node provides the network interface in the public subnet
so the ALB can reach the pod IPs.

---

## 4. Frontend (Next.js) — and how it calls the backend

### What problem it solves
The frontend is the web page users see. But the browser must never talk to
backend services directly (they're private, and exposing them is insecure).

### The clever part — Next.js middleware proxy
The browser calls a RELATIVE path: `/api/users/login` (no domain).
The Next.js SERVER (not the browser) then forwards that to the Internal ALB.

```
Browser → GET /api/users/login  (relative, hits the frontend pod)
   │
Next.js middleware reads INTERNAL_API_URL from the ConfigMap
   │
Forwards → http://<internal-alb>/api/users/login
   │
Internal ALB → user-service → response back to browser
```

### What problem THIS solves + alternatives we rejected
- **Rejected: `NEXT_PUBLIC_API_URL` baked at build time.** The internal ALB DNS
  changes on every rebuild. We'd have to rebuild the Docker image every time.
- **Rejected: expose backend services to the internet.** Insecure.
- **Chosen: server-side proxy via middleware.** The browser never sees the
  internal URL. Same Docker image works in any region (reads env var at runtime).
  This is why the app works identically in primary and DR.

### 🏨 Simple analogy — frontend proxy
The frontend is like the **hotel concierge**. A guest asks the concierge "book me
a taxi" (`/api/...`). The guest doesn't call the taxi company directly — the
concierge (frontend server) makes the call on their behalf, using the internal
phone directory (INTERNAL_API_URL). The guest never sees the taxi company's number
(the backend is hidden and secure).

### Why middleware not rewrites (a bug we hit)
Next.js `rewrites()` are baked at BUILD time — the internal ALB URL was frozen as
`http://localhost` because the env var wasn't set at build. We switched to
`middleware.ts` which reads `INTERNAL_API_URL` on EVERY request at runtime.

---

## 5. Internal ALB — private backend router

### What problem it solves
There are 6 backend services. The frontend needs to reach the right one based on
the path. And backend services must NEVER be reachable from the internet.

### What we made
An INTERNAL ALB (scheme: internal — no public IP, lives in private subnets).
Path-based routing:
- `/api/users`    → user-service:4001
- `/api/products` → product-service:4002
- `/api/cart`     → cart-service:4003
- `/api/orders`   → order-service:4004
- `/api/payments` → payment-service:4005

### 🏢 Simple analogy — Internal ALB
The internal ALB is the **office building's internal mail room**. Letters arrive
addressed to departments: "to HR" (`/api/users`), "to Sales" (`/api/products`),
"to Accounts" (`/api/payments`). The mail room reads the department name on the
envelope (the URL path) and delivers to the right floor. It's INSIDE the building —
outsiders can't drop mail here directly (private, no public IP).

### Why it's here + alternatives
- **Rejected: one NLB per service** — 6 load balancers, 6× cost, complex.
- **Rejected: service mesh (Istio)** — powerful but heavy, overkill for 6 services.
- **Rejected: Kubernetes ClusterIP + DNS only** — works pod-to-pod but the
  frontend proxy needs one stable entry point.
- **Chosen: one internal ALB, path routing** — single entry point, cheap, simple,
  and the same pattern as the external ALB.

---

## 6. Backend services — and how they connect to the DB

### What we made
6 Node.js/Express microservices, each in its own pod, each owning its own database:
- user-service → user_db
- product-service → product_db
- cart-service → cart_db
- order-service → order_db
- payment-service → payment_db
- notification-service → (no DB — sends emails/SMS)

### How a service connects to the database
1. The pod's `DATABASE_URL` env var comes from a Kubernetes Secret
2. That Secret is synced from AWS SSM Parameter Store by the Secrets Store CSI Driver
3. The URL points to the Aurora WRITER endpoint (not the RDS Proxy — see below)
4. Prisma (the ORM) uses this URL to run queries

### Why writer endpoint, not RDS Proxy (a bug we hit)
RDS Proxy is designed for connection pooling, but its TLS handshake doesn't work
with Prisma's driver on Aurora PostgreSQL 17 (error P1001). psql works, Prisma
doesn't. So we point Prisma at the Aurora writer endpoint directly. Prisma does
its own connection pooling anyway.

### Why the `#` in the password broke things
The DB password `PipEcom2026#Dev` contains `#`, which is a URL fragment delimiter.
In a connection string, everything after `#` is ignored — Prisma saw an empty
port and failed. Fix: URL-encode `#` as `%23`.

### How services talk to each other
Order-service calls payment-service to verify a payment before creating an order.
This goes via the internal service URL with an `x-internal-key` header — a shared
secret that proves the caller is another trusted service, not an end user. Internal
endpoints (`/internal/*`) return 403 if the key is wrong.

---

## 7. Aurora PostgreSQL — the database

### What problem it solves
The app needs a durable, highly-available relational database that survives
node failures and can replicate across regions for DR.

### What we made
- **Aurora PostgreSQL cluster** (not plain RDS) — 1 writer + 2 readers across AZs
- **Aurora Global Database** — replicates to a secondary cluster in us-west-2
  with < 1 second lag (this is the cross-region replica for DR)
- Encrypted with KMS, automated backups, deletion protection

### Why Aurora not plain RDS
- Aurora replicates in < 1s across regions (plain RDS is minutes)
- Aurora auto-scales storage, has faster failover
- Aurora Global Database is purpose-built for the exact DR pattern we need

### Why 1 writer + 2 readers
- Writer handles all writes (register, orders, payments)
- Readers handle read queries (product browsing) — spreads load
- Readers in different AZs — if one AZ dies, others survive

---

## 8. ElastiCache (Redis)

### What problem it solves
Some data is read constantly (product catalog, cart contents). Hitting the
database every time is slow and expensive. Redis caches this in memory (microsecond
reads).

### What we made
An ElastiCache Redis replication group (primary + replica) in private subnets,
encrypted, with an AUTH token.

### Honest status
Redis is provisioned but the app code doesn't connect to it yet — it's ready for
when caching is added (session store, cart cache, product cache). Documented
honestly rather than pretending it's wired.

---

## 9. S3 Buckets — for ALB + WAF logs

### What problem it solves
When something goes wrong (attack, error spike), you need logs to investigate.
ALB access logs and WAF blocked-request logs are stored in S3 for audit.

### What we made
An S3 bucket (`pip-project-ecommerce-logs-prod-<account>`), encrypted with KMS,
versioned, lifecycle rules (transition to Glacier after 365 days, expire after
730). Both ALB and WAF write logs here via a bucket policy + Firehose.

---

## 10. SNS + SQS — notifications

### What problem it solves
When a user registers, pays, or orders, the system should notify them (email/SMS)
WITHOUT making them wait. Decouple the action from the notification.

### What we made
- **SNS topic** — services publish events ("USER_REGISTERED", "PAYMENT_SUCCESS")
- **notification-service** — subscribes, sends email (SES) / SMS (SNS)
- The publishing service doesn't wait — it fires the event and moves on (async)

### SNS vs SQS
- **SNS** = pub/sub, one-to-many, push. One event → many subscribers.
- **SQS** = queue, one-to-one, pull. Guarantees delivery even if consumer is down.
We use SNS for fan-out notifications. SQS could be added for guaranteed order
processing (a durable work queue) if needed.

---

## 11. CloudWatch — monitoring

### What problem it solves
You can't fix what you can't see. CloudWatch collects metrics, logs, and fires
alarms when something is wrong.

### What we made
- **26 alarms** — Aurora CPU/memory/connections, Redis, ALB 5xx/latency/unhealthy,
  EKS node CPU/memory/pod-restarts, WAF blocks, NAT errors, GuardDuty, Route53
  health, plus 4 ML anomaly-detection alarms
- **3 dashboards** — Infrastructure, Application, Business
- **5 Logs Insights saved queries** — error rate, slow requests, DB errors, user
  activity, pod crashes
- **Alarms → SNS → Slack/PagerDuty** — a Lambda forwards alarms to Slack

---

### 🏦 Simple analogy — Aurora Global Database
Aurora is the **bank's central ledger**. The primary branch (us-east-1) records
every transaction. A mirror branch in another city (us-west-2) copies every entry
within 1 second. If the main branch burns down, the mirror branch has every
record and instantly becomes the new head office. No customer loses their balance.

### 📮 Simple analogy — SNS notifications
SNS is the **post office bulletin board**. When something happens ("payment
succeeded"), the service pins a notice on the board and walks away — it doesn't
wait. Anyone subscribed (notification-service) sees the notice and acts (sends
email/SMS). The original service isn't slowed down waiting for the email to send.

---

## How the Pods Are Connected — Full Picture

```
                        INTERNET
                           │
                    ┌──────▼──────┐
                    │  Route53    │  pip-ecommerce.com → ALB
                    └──────┬──────┘
                    ┌──────▼──────┐
                    │  WAF        │  blocks attacks
                    └──────┬──────┘
              ┌────────────▼────────────┐
              │   External ALB (public)  │  in PUBLIC subnets
              └────────────┬────────────┘
                           │ /
              ┌────────────▼────────────┐
              │   frontend pods (Next.js)│  in PRIVATE subnets
              │   ClusterIP: frontend-svc│
              └────────────┬────────────┘
                           │ /api/* (server-side proxy)
              ┌────────────▼────────────┐
              │   Internal ALB (private) │  in PRIVATE subnets
              └────────────┬────────────┘
          ┌────────┬───────┼───────┬────────┐
          │/api/   │/api/  │/api/  │/api/   │
          │users   │products cart  │orders  │payments
          ▼        ▼       ▼       ▼        ▼
      ┌──────┐ ┌──────┐ ┌────┐ ┌─────┐ ┌───────┐
      │user  │ │product│ │cart│ │order│ │payment│  backend pods
      │:4001 │ │:4002  │ │:4003││:4004│ │:4005  │  (PRIVATE subnets)
      └──┬───┘ └──┬───┘ └─┬──┘ └──┬──┘ └───┬───┘
         │        │       │       │        │
         └────────┴───────┼───────┴────────┘
                          ▼
              ┌────────────────────────┐
              │   Aurora PostgreSQL     │  in DATABASE subnets
              │   user_db, product_db,  │  (most isolated tier)
              │   cart_db, order_db,    │
              │   payment_db            │
              └────────────────────────┘

  order-service ──x-internal-key──► payment-service  (verify payment)
  order-service ──x-internal-key──► user-service     (get contact info)
  any service   ──publish event──► SNS ──► notification-service ──► email/SMS
```

### The three connection types
1. **North-south (external)**: internet → Route53 → WAF → External ALB → frontend
2. **North-south (internal)**: frontend → Internal ALB → backend service → Aurora
3. **East-west (service-to-service)**: order → payment / order → user, using the
   internal service key header, and async events via SNS

---

## What Problem Does This SaaS Platform Solve?

### The business problem
Selling products online at scale requires: handling many users at once, never
losing an order, staying up 24/7 even if a server or an entire AWS region fails,
being secure against attacks, and being cheap to run when quiet but able to scale
when busy.

### How each piece solves part of it

| Business need | Technical solution |
|---------------|-------------------|
| "Never lose an order" | Aurora (durable, backed up) + Global DB replica |
| "Stay up if a server dies" | 3 nodes across 3 AZs + K8s auto-restart |
| "Stay up if a REGION dies" | Route53 failover → DR region (us-west-2) |
| "Handle traffic spikes" | HPA (pod autoscale) + Cluster Autoscaler (node autoscale) |
| "Block hackers" | WAF + private subnets + security group layering |
| "Notify users instantly" | SNS async events (don't block the checkout) |
| "Know when something breaks" | CloudWatch 26 alarms → Slack |
| "Keep secrets safe" | Secrets Manager/SSM + IRSA temporary tokens |
| "Cheap when quiet" | Small nodes + warm-standby DR (scales up only on failover) |

---

## Summary — the whole picture

| Layer | Component | One-line purpose |
|-------|-----------|------------------|
| DNS | Route53 | name → ALB, health-check failover |
| Security | WAF | block attacks before the app |
| Entry | External ALB | internet → frontend pods |
| Web | Next.js frontend | serve pages, proxy /api server-side |
| Routing | Internal ALB | /api/* → correct backend service |
| Logic | 6 microservices | business logic per domain |
| Data | Aurora Global DB | durable storage, cross-region replica |
| Cache | ElastiCache | fast in-memory reads (ready) |
| Async | SNS | fire-and-forget notifications |
| Logs | S3 | ALB + WAF audit logs |
| Observe | CloudWatch | metrics, alarms, dashboards |
