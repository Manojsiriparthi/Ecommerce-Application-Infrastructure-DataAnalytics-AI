# 30-Minute Demo Script — pip-project-ecommerce

A paragraph-by-paragraph script for a live demo. Timed in two halves:
**Part A (0–10 min): architecture & workflow** — explain each component and how
they communicate, following the request from Route53 all the way to RDS.
**Part B (10–20 min): the code** — open each cited file:line and show the exact
configuration. **Part C (20–30 min): live demo + Q&A** — run it and field
questions.

Account `497149484677` · Primary `us-east-1` · DR `us-west-2` · `pip-ecommerce.com`

---

## The architecture diagram (show this first)

```
                              ┌─────────────┐
                              │   Browser   │
                              └──────┬──────┘
                                     │  https://pip-ecommerce.com
                                     ▼
                          ┌──────────────────────┐
                          │  Route53 (DNS)        │  alias A-record, PRIMARY/
                          │  + health checks      │  SECONDARY failover
                          └──────────┬────────────┘
              resolves to the healthy region's ALB
                                     ▼
                          ┌──────────────────────┐
                          │  AWS WAF (OWASP)      │  filters bad requests
                          └──────────┬────────────┘
                                     ▼
                 ┌───────────────────────────────────┐
                 │   External ALB (public subnets)    │  TLS via ACM (443)
                 │   internet-facing                  │
                 └──────────────────┬─────────────────┘
                                    ▼
                 ┌───────────────────────────────────┐
                 │   Frontend pods (Next.js)          │  private subnets
                 │   middleware proxies /api/*        │
                 └──────────────────┬─────────────────┘
                                    ▼
                 ┌───────────────────────────────────┐
                 │   Internal ALB (private subnets)   │  path routing
                 │   /api/users /api/products ...      │
                 └──────────────────┬─────────────────┘
          ┌──────────┬──────────────┼──────────────┬───────────┐
          ▼          ▼              ▼              ▼           ▼
       user      product         cart           order      payment   (+notification)
       :4001     :4002           :4003          :4004       :4005
          │          │              │              │           │
          │          │              └──────┬───────┘           │
          ▼          ▼                     ▼                    ▼
   ┌────────────────────────┐      ┌───────────────┐    (writes/idempotency)
   │  Aurora PostgreSQL     │      │ ElastiCache   │
   │  writer + 2 readers    │◄─────│ Redis (cache) │
   │  (database subnets)    │      │ sessions/cart │
   └───────────┬────────────┘      └───────────────┘
               │ Global DB replication (<1s)
               ▼
     us-west-2 Aurora secondary (read-only) ── DR region mirrors all of the above

   Secrets path (dashed): pods ──IRSA/OIDC──► IAM role ──► Secrets Store CSI
                          ──► SSM / Secrets Manager (KMS-encrypted) ──► mounted into pod
   Observability: VPC Flow Logs + WAF logs + CloudTrail ──► CloudWatch (audit)
```

---

# PART A — Architecture & workflow (0–10 min)

### 1. Opening (what this is)
"This is a multi-region e-commerce platform on AWS EKS. Everything is Terraform
infrastructure-as-code, deployed via a GitOps flow with ArgoCD. It runs in two
regions — us-east-1 as primary and us-west-2 as a disaster-recovery standby — with
an Aurora Global Database replicating the data between them. Let me walk a single
request from the browser all the way to the database."

### 2. Route53 — the front door
"When a user types `pip-ecommerce.com`, the first stop is Route53, our DNS. We
don't use a plain IP because our load balancer's IP changes — so we use a Route53
**alias A-record** that points at the ALB by name and always returns its current
IPs. On top of that, we configured **failover records**: a PRIMARY record for the
us-east-1 load balancer with a health check, and a SECONDARY record for the
us-west-2 DR load balancer. If the primary region becomes unhealthy, Route53
automatically starts handing out the DR region's address. That's the automatic
traffic failover we'll demo later."

### 3. WAF — the security filter
"Before any traffic reaches the application, it passes through AWS WAF attached to
the load balancer. WAF runs AWS-managed rule groups — the OWASP common rule set,
known-bad-inputs, SQL-injection protection, and an IP reputation list. So
malicious requests are dropped at the edge, before they ever hit a pod. Every WAF
decision is logged for auditing."

### 4. External ALB — the public entry point
"The healthy region's external Application Load Balancer sits in the public
subnets. It's internet-facing and terminates TLS using an ACM certificate, so the
user gets HTTPS. The ALB forwards to the frontend pods. We use ACM because it
gives us a free, browser-trusted, auto-renewing certificate — and it attaches
directly to the ALB listener."

### 5. Frontend (Next.js) — presentation tier
"The ALB routes to the frontend, a Next.js app running in the private subnets. The
frontend never talks to the backend services directly. Instead, its middleware
intercepts every `/api/*` call and proxies it, at runtime, to the **internal**
load balancer. This keeps all backend services private and avoids CORS entirely —
the browser only ever talks to one origin."

### 6. Internal ALB — service routing
"The internal ALB lives in the private subnets and is not reachable from the
internet. It does **path-based routing**: `/api/users` goes to user-service,
`/api/products` to product-service, `/api/cart` to cart-service, and so on. We
chose an internal ALB rather than exposing each service publicly because it gives
us one private, controlled entry point to the microservices, with health checks
and routing in one place."

### 7. The microservices — why this split
"We split the app into focused services — user, product, cart, order, payment,
notification — each owning its own database. This is the classic e-commerce
pattern: the services scale and fail independently. If the payment service is
under load, it scales without affecting product browsing. Each service runs as its
own Kubernetes deployment."

### 8. The three tokens — how trust works
"Three different secrets solve three different trust problems. The **JWT token**
proves the end user's identity: on login, user-service signs a token with a shared
secret, and every service can verify it independently — no shared session store
needed. The **internal service key** proves that a *service*, not a browser, is
calling an internal-only endpoint like `/internal/users/:id`; a browser never has
that key. And the **Redis AUTH token** proves a service is allowed to use the
cache. Three secrets, three boundaries — user identity, service identity, cache
access."

### 9. ElastiCache Redis — why we cache
"Redis solves the hot-path problem. The cart is read on every single page view —
if that hit Aurora each time, the database would be the bottleneck. So the active
cart lives in Redis and is only written to Aurora at checkout. Redis also holds
logout token blacklists, rate-limit counters that work correctly across all pod
replicas, and payment idempotency keys so a retried payment never double-charges.
It's a cache, not a database — it lives in the private subnets, and losing it
doesn't lose any order data."

### 10. Aurora + Global Database — the system of record
"The real data lives in Aurora PostgreSQL in the database subnets — a writer plus
two readers across availability zones. For disaster recovery we enabled the Aurora
**Global Database**: the us-west-2 secondary continuously replicates from the
primary with under a second of lag. During normal operation the DR copy is
read-only. If we fail over, we promote it to writable. That's how the DR region
can take over with the same data."

### 11. How pods get credentials — the security chain
"Here's the part people always ask: how does a pod get the database password
without it being baked into the image? We use **IRSA** — IAM Roles for Service
Accounts. Each pod runs as a Kubernetes ServiceAccount that's mapped to an AWS IAM
role through the cluster's OIDC provider. The **Secrets Store CSI driver** uses
that identity to fetch the database URL, JWT secret, and Redis token from SSM
Parameter Store and Secrets Manager — all encrypted with KMS — and mounts them
into the pod. The pod reads `DATABASE_URL` as an environment variable from a
Kubernetes secret. No secret is ever in git, in the image, or in a plain config
map. The IAM role is least-privilege: it can only read this project's parameters."

### 12. Observability & audit — Flow Logs, WAF logs, CloudTrail
"For security and auditing we capture three streams into CloudWatch: **VPC Flow
Logs** record every network connection in the VPC — invaluable for 'who connected
to the database' investigations; **WAF logs** record every blocked/allowed request;
and **CloudTrail** records every AWS API call. These give us a complete audit trail
for compliance and incident response."

### 13. Close Part A
"So the full path is: browser → Route53 → WAF → external ALB → frontend →
internal ALB → the right microservice → Aurora and Redis. Secrets flow in
separately through IRSA. And the whole thing is mirrored in a second region for
disaster recovery. Now let me show you the actual configuration."

---

# PART B — The code (10–20 min)

> Open each file at the cited line and read the explanation aloud. These are real
> line references in this repo.

### B1. Route53 hosted zone + alias record
**File:** `01-Infrastructure/modules/route53-acm/main.tf`
- **Line ~27** `resource "aws_route53_zone" "ecommerce"` — "This creates the hosted
  zone for pip-ecommerce.com. Its nameservers are what we pasted into Namecheap."
- **Line ~42** `resource "aws_acm_certificate" "ecommerce"` — "DNS-validated ACM
  cert for the domain; Route53 adds the validation record automatically."
- **Line ~206** `resource "aws_route53_health_check" "primary"` — "This health
  check pings the primary ALB. If it fails, Route53 fails over to SECONDARY."
- The **apex_primary / apex_dr** records (failover_routing_policy PRIMARY/
  SECONDARY) — "This is the automatic failover: one record per region, primary has
  the health check, secondary is the DR fallback."

### B2. JWT + internal key + where they're verified
**File:** `02-Application-Code/services/user-service/src/index.ts`
- **Line 3** `secret=process.env.JWT_SECRET` — "The shared signing secret."
- **Login handler** (`app.post('/api/users/login'...)`) — "On success we
  `jwt.sign` a token with the user id. Note it also publishes a login event to SNS
  — that's why the pod's IAM role needs KMS-for-SNS permission."
- **`auth` middleware** (`jwt.verify(h.slice(7), secret)`) — "Every protected route
  verifies the token with the same secret."
- **`/internal/users/:id`** (`if(req.headers['x-internal-key']!==internalKey)`) —
  "This is the internal service key check — a browser can't reach this; only
  another service with the key can."

### B3. How secrets are declared for pods
**File:** `03-Kubernetes/secrets/secretproviderclass-db.yaml`
- Show the **cart-service-secrets** block — "This SecretProviderClass tells the CSI
  driver exactly which AWS values to fetch: the DB URL and JWT secret from SSM, and
  the Redis auth token from Secrets Manager via a JMESPath. It then exposes them as
  Kubernetes secrets the pod mounts." This is the 'how pods fetch secrets' answer.

### B4. The IAM permissions pods get (and why)
**File:** `01-Infrastructure/modules/iam-irsa/main.tf`
- **`aws_iam_policy "ecommerce_services"`** — read the statements:
  - `ReadSecretsManager` / `ReadSSMParameters` — "scoped to only this project's
    paths — least privilege."
  - `DecryptKMS` with `kms:ViaService` including **sns** — "KMS decrypt for the
    secrets, and the sns entry is required because login publishes to a
    KMS-encrypted SNS topic; without it, login returns 500."
  - `PublishSNS`, `SendSES`, `PullECR` — "exactly what the services need, nothing
    more." This is the 'what permission we mention and why' answer.
- Mention: **IRSA roles are per-cluster** (OIDC-bound), so the DR cluster has its
  own `-dr-services-role`.

### B5. How the pod consumes the credential
**File:** `03-Kubernetes/services/*/deployment.yaml` (e.g. user-service)
- Show `serviceAccountName: ecommerce-services-sa` (the IRSA identity), the
  `aws-secrets` CSI volume, and `DATABASE_URL` via `secretKeyRef`. "This closes the
  loop — the pod runs as the SA, the CSI driver mounts the secret, the app reads
  DATABASE_URL."

### B6. Internal ALB routing — why and how
**File:** `03-Kubernetes/services/ingress-internal.yaml`
- Show `scheme: internal` and the path rules (`/api/users`→4001, etc.). "Internal
  so it's private; path routing so one ALB serves all services."
**File:** `02-Application-Code/frontend/middleware.ts`
- Show the proxy to `process.env.INTERNAL_API_URL`. "This is why we use an internal
  LB and a runtime proxy — backends stay private, no CORS, and the ALB DNS is read
  at runtime from the ConfigMap."

### B7. ElastiCache — the config and the why
**File:** `01-Infrastructure/modules/elasticache/main.tf`
- Top comment block lists the 4 use cases. Show the SG (`6379 from EKS nodes
  only`) and the `redis_auth` Secrets Manager secret. "Cache in private subnets,
  auth-protected, reachable only from the nodes."

### B8. WAF — the rules and logging
**File:** `01-Infrastructure/modules/waf/main.tf`
- **Line ~144** `aws_wafv2_web_acl "ecommerce"` — show the managed rule groups:
  `AWSManagedRulesCommonRuleSet` (~165), `KnownBadInputs` (~188), `SQLiRuleSet`
  (~211), `AmazonIpReputationList` (~257).
- **Line ~309** `aws_wafv2_web_acl_logging_configuration` — "every request logged
  to the firehose → S3 for audit."

### B9. VPC Flow Logs — audit
**File:** `01-Infrastructure/modules/security/main.tf`
- **Line ~298** `aws_iam_role "vpc_flow_logs"` and **~336**
  `aws_cloudwatch_log_group "vpc_flow_logs"` (`/aws/vpc/flowlogs/...`, 90-day
  retention). "This is our network audit trail — every connection in the VPC."

### B10. Network tiers + the EKS→Aurora rule
**File:** `01-Infrastructure/modules/networking/main.tf`
- **Line ~4** `aws_vpc` with `kubernetes.io/cluster/...=shared` tag, **~47** public
  subnet `kubernetes.io/role/elb=1`. "EKS discovery tags."
**File:** `01-Infrastructure/environments/prod/main.tf`
- `aws_security_group_rule "aurora_allow_eks_nodes"` — "This is the one rule that
  lets pods reach Aurora on 5432 from the EKS node security group. Miss it and pods
  can't reach the DB even though it's healthy."

---

# PART C — Live demo + Q&A (20–30 min)

### C1. Show it's live
- Browser: `https://pip-ecommerce.com` loads, products listed, log in, add to cart.
- Terminal: `dig +short pip-ecommerce.com @8.8.8.8` → primary ALB IPs.

### C2. Show the two regions
```bash
kubectl --context <east> get pods -n ecommerce     # 7 pods Running
aws rds describe-global-clusters \
  --global-cluster-identifier pip-project-ecommerce-global-db \
  --region us-east-1 --query "GlobalClusters[0].GlobalClusterMembers[*].{C:DBClusterArn,Writer:IsWriter}"
```

### C3. Live DR failover (the highlight)
```bash
# Simulate primary outage — scale frontend to 0 (ALB loses healthy targets)
kubectl scale deployment/frontend-deployment --replicas=0 -n ecommerce
# Watch the domain flip to the DR region (~2-3 min)
watch -n 10 'dig +short pip-ecommerce.com @8.8.8.8'
#   IPs change from us-east-1 → us-west-2
# Restore
kubectl scale deployment/frontend-deployment --replicas=1 -n ecommerce
```
"Route53 saw the primary ALB had no healthy targets and automatically routed the
domain to the DR region in us-west-2. That's our RTO in action — no manual DNS
change."

### C4. Show a rollback (optional)
```bash
kubectl rollout history deployment/user-service-deployment -n ecommerce
kubectl rollout undo deployment/user-service-deployment -n ecommerce   # instant
```
"And for a bad app version, rollback is one command — or in GitOps, we revert the
commit and ArgoCD re-syncs the previous version."

---

## Anticipated questions — crisp answers

- **Why alias A-record not CNAME?** CNAME is illegal at the zone apex and the ALB
  has no fixed IP; an alias A-record returns the ALB's live IPs and auto-follows.
- **Why ACM?** Free, browser-trusted, auto-renewing TLS attached to the ALB.
  Regional — the DR region needs its own us-west-2 cert.
- **Why JWT + a separate internal key?** JWT proves the *user*; the internal key
  proves a *service* for private endpoints. Different trust boundaries.
- **How do pods get secrets?** IRSA (ServiceAccount→IAM via OIDC) + Secrets Store
  CSI driver fetches KMS-encrypted SSM/Secrets-Manager values and mounts them.
  Never in the image or git.
- **What permission did we grant and why?** Read this project's SSM + Secrets
  Manager, KMS decrypt (incl. via SNS for the login event), publish SNS, send SES,
  pull ECR — least privilege, scoped by ARN.
- **Why Redis?** Offload Aurora on the hottest reads (cart/session) and make
  cross-replica correctness possible (rate limits, idempotency, logout blacklist).
- **Why an internal ALB?** One private, controlled entry to all microservices with
  path routing and health checks; backends never exposed to the internet.
- **Why Flow Logs / WAF logs / CloudTrail?** Network, request, and API audit
  trails for security, compliance, and incident investigation.
- **How does failover work?** Route53 PRIMARY/SECONDARY records + health/target
  checks route the domain to the DR ALB automatically; DB promotion is a separate
  deliberate step to avoid split-brain.
```
