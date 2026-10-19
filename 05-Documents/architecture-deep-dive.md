# Architecture Deep Dive — pip-project-ecommerce

A complete architectural explanation of the platform: why each component exists,
what problem it solves, and how the pieces fit together. Written for interview
prep and onboarding. Where something is a design (not yet built in this repo),
it is labelled **[DESIGN]**.

Account: `497149484677` · Primary: `us-east-1` · DR: `us-west-2` · Domain: `pip-ecommerce.com`

![alt text](<WhatsApp Image 2026-09-29 at 00.13.52-1.jpeg>)
---

## 1. The big picture

A multi-region e-commerce SaaS on AWS EKS, provisioned with Terraform, deployed
with a GitOps flow (ArgoCD), fronted by a custom domain over HTTPS, with an
Aurora Global Database for cross-region disaster recovery.

```
                         Internet
                            │
                   Route53 (pip-ecommerce.com)
                   PRIMARY / SECONDARY failover
                            │
            ┌───────────────┴────────────────┐
       us-east-1 (PRIMARY)              us-west-2 (DR, warm standby)
            │                                  │
          WAF                                WAF
            │                                  │
   External ALB (HTTPS/ACM)          External ALB (HTTP)
            │                                  │
     Frontend pods (Next.js)          Frontend pods
            │                                  │
   Internal ALB  ── /api/* ──►        Internal ALB
   user / product / cart /            (same services)
   order / payment / notification
            │                                  │
   Aurora PostgreSQL (writer)  ──►  Aurora secondary (read-only)
   ElastiCache Redis                 (Global DB replication, <1s)
```

Request flow for a page: Internet → Route53 resolves the domain → WAF filters →
external ALB → frontend (Next.js) pod → the frontend's middleware proxies
`/api/*` → internal ALB → the matching backend service → Aurora / Redis.

---

## 2. Why the tokens exist — JWT, Redis AUTH, internal service key

The platform uses **three different secrets for three different trust problems.**
They are not interchangeable.

### 2.1 JWT secret — *proves who the end user is*
- **Problem it solves:** HTTP is stateless. After a user logs in, every later
  request ("show my cart", "place my order") must prove it's the same
  authenticated user — without the server storing a session for each one.
- **How:** on successful login, user-service signs a JSON Web Token with the
  shared `JWT_SECRET` (`jwt.sign({sub:userId,email}, secret, {expiresIn:'1h'})`).
  The browser sends it as `Authorization: Bearer <token>` on later calls. Each
  service verifies the signature with the **same** secret (`jwt.verify`). A valid
  signature = the token was issued by us and hasn't been tampered with.
- **Why one shared secret across services:** any service (cart, order, payment)
  must independently validate a token issued by user-service. They all share
  `JWT_SECRET` so verification works anywhere without calling back to
  user-service. (Seen in `user-service/src/index.ts`: `secret=process.env.JWT_SECRET`.)
- **Why it must match across regions:** after a DR failover, tokens issued in
  us-east-1 must still validate in us-west-2 — so the DR region is given the
  **same** `JWT_SECRET` value (see `dr-app-secrets.tf`).

### 2.2 Internal service key — *proves one service is calling another*
- **Problem it solves:** some endpoints are internal-only (e.g.
  `GET /internal/users/:id`), meant to be called service-to-service, never by a
  browser. A JWT proves a *user*; it does not prove a *service*.
- **How:** internal endpoints require the header `x-internal-key` to equal
  `INTERNAL_SERVICE_KEY`. (In code: `if(req.headers['x-internal-key']!==internalKey)
  return res.status(403)`.) A browser never has this key, so it cannot reach
  internal routes even with a valid user JWT.
- **Why separate from JWT:** different trust boundary. JWT = user identity (public
  edge). Internal key = service identity (private mesh). Mixing them would let a
  logged-in user hit internal admin paths.

### 2.3 Redis AUTH token — *proves the service may use the cache*
- **Problem it solves:** ElastiCache Redis is a shared in-memory store. Without
  auth, anything that reaches it on the network can read/write sessions and carts.
- **How:** Redis is configured with an AUTH token; services present it to connect.
  Stored in Secrets Manager (`pip-project-ecommerce/prod/redis/auth-token`) and
  mounted into cart/payment pods via the CSI driver.
- **Why Secrets Manager (not SSM) for this one:** it's a standalone raw secret
  value, and Secrets Manager supports rotation. The DB URLs and JWT secret are
  stored in **SSM SecureString** instead (see §6).

**Summary table**

| Secret | Proves | Where stored | Who uses it |
|---|---|---|---|
| JWT secret | the end user's identity | SSM SecureString | all services (verify) |
| Internal service key | a service's identity | SSM SecureString | internal `/internal/*` routes |
| Redis AUTH token | right to use the cache | Secrets Manager | cart, payment |

---

## 3. Why Redis (ElastiCache) — what problem it solves

Redis is **not a database**; it's an ephemeral cache that removes load from Aurora
and makes correctness possible across multiple pod replicas. Four concrete jobs
(documented in `modules/elasticache/main.tf`):

1. **Session / token blacklist (user-service).** JWTs are stateless — you can't
   "cancel" one. On logout, the token's ID is stored in Redis with a TTL matching
   the token expiry, so a logged-out token is rejected. Zero DB hits per auth check.
2. **Cart caching (cart-service).** The cart is read on every page view. Keeping
   the active cart in Redis (TTL ~24h) means the most frequent operation never
   touches Aurora. The cart is written to Aurora only at checkout. This is the
   standard high-traffic e-commerce pattern.
3. **Rate-limit counters.** Redis atomic `INCR`+`EXPIRE` gives per-IP/per-user
   counters that are correct across all pod replicas — impossible with in-process
   memory counters (each pod would count separately).
4. **Idempotency keys (payment-service).** Payment retries must not double-charge.
   Redis stores payment idempotency keys (short TTL) as a dedup store — far
   cheaper and faster than a DB unique-constraint check.

**Placement:** Redis lives in **private subnets** (same tier as EKS workers), not
database subnets, because it is cache, not a system of record. Aurora lives in the
database subnets.

---

## 4. DNS: why CNAME vs A-record, and why an ALIAS A-record

### The constraint
- An **A record** maps a name → IP address(es).
- A **CNAME** maps a name → another name.
- **Rule:** you cannot put a CNAME at the zone apex (the bare `pip-ecommerce.com`).
  DNS forbids a CNAME coexisting with the SOA/NS records that must exist at the apex.

### The problem
An ALB has **no fixed IP** — AWS changes its IPs freely. So you can't hardcode an
A record with an IP, and you can't CNAME the apex to the ALB's DNS name.

### The solution — Route53 **ALIAS A-record**
An alias A-record is an AWS-specific record that points at an AWS resource (the
ALB) by name but **answers like an A record** (returns the ALB's current IPs,
refreshed automatically). This is why the apex record in `route53-acm/main.tf`
is an alias:
```hcl
alias {
  name    = <alb_dns_name>
  zone_id = <alb_zone_id>
  evaluate_target_health = true
}
```
- **Apex (`pip-ecommerce.com`)** → alias A-record (CNAME not allowed here).
- **`www.`** → also an alias A-record here (could be a CNAME, kept as alias for
  consistency + health evaluation).
- **Benefit:** when the ALB's IPs change (or the ALB is rebuilt), the alias
  auto-follows — no record edit needed, no TTL games.

---

## 5. Why ACM certificate is required (and the regional catch)

- **Problem:** browsers require HTTPS; HTTPS needs a TLS certificate the browser
  trusts. A self-signed cert triggers warnings.
- **ACM** issues a free, auto-renewing, publicly-trusted certificate for
  `pip-ecommerce.com`. It's validated via DNS (a CNAME ACM asks you to add, which
  Route53 does automatically in `route53-acm`).
- **Attachment:** the cert is attached to the **ALB listener** (443) via the
  ingress annotation `alb.ingress.kubernetes.io/certificate-arn`. The ALB
  terminates TLS; traffic inside the VPC (ALB→pods) is plain HTTP, which is normal.
- **Regional catch:** ACM certs for ALBs are **regional**. A REGIONAL ALB in
  us-west-2 needs a cert issued **in us-west-2**. The us-east-1 cert cannot be
  attached to the DR ALB. (This is why, during the DR demo, the DR ALB served
  HTTP only — no us-west-2 cert yet. A full DR HTTPS setup needs a us-west-2 ACM
  cert.)
- **CNAME/A vs cert:** the cert is tied to the **domain**, not the ALB. Changing
  the ALB does NOT require reissuing the cert — only re-pointing the Route53 alias.

---

## 6. How a pod gets database credentials — IRSA + Secrets Store CSI (the key scenario)

This is the most-asked "how does it actually work" question. **No secret is ever
baked into an image or a plain env var in git.** Here is the full chain.

### The actors
- **IRSA** (IAM Roles for Service Accounts): maps a Kubernetes ServiceAccount to
  an AWS IAM role via the cluster's OIDC provider.
- **Secrets Store CSI driver**: a Kubernetes add-on that mounts secrets from AWS
  SSM / Secrets Manager into a pod as files (and optionally as K8s Secrets).
- **SecretProviderClass**: declares WHICH AWS parameters/secrets to fetch and how
  to expose them (`03-Kubernetes/secrets/secretproviderclass-db.yaml`).

### Step-by-step: how `cart-service` gets its DB URL + Redis token
1. The pod runs under ServiceAccount **`ecommerce-services-sa`**, which is
   annotated with an IAM role ARN (`...-services-role`, or `-dr-services-role` in
   the DR region).
2. When the pod starts, EKS injects a short-lived **OIDC web-identity token**.
3. The Secrets Store CSI driver, acting for the pod, calls
   `sts:AssumeRoleWithWebIdentity` with that token → gets temporary AWS creds for
   the services role. (If the role's trust policy doesn't trust this cluster's
   OIDC provider, you get `AccessDenied` — exactly the cross-region bug we hit.)
4. Using those creds, the driver fetches the objects named in the
   `cart-service-secrets` SecretProviderClass:
   - `/pip-project-ecommerce/prod/db/cart-url` (SSM SecureString) → alias
     `database_url`
   - `/pip-project-ecommerce/prod/app/jwt-secret` (SSM SecureString)
   - `pip-project-ecommerce/prod/redis/auth-token` (Secrets Manager, JMESPath
     `auth_token`)
5. The SecureString/secret values are **KMS-encrypted at rest**; the role also has
   `kms:Decrypt` (with a `kms:ViaService` condition for secretsmanager/ssm — and
   `sns` for the login-publish path). The driver decrypts via KMS.
6. The driver writes them into a Kubernetes Secret (e.g. `cart-db-url`,
   `redis-secrets`) and mounts them. The container reads `DATABASE_URL` from that
   secret as an env var:
   ```yaml
   env:
   - name: DATABASE_URL
     valueFrom: { secretKeyRef: { name: cart-db-url, key: database_url } }
   ```
7. Prisma connects to Aurora using `DATABASE_URL`.

### Why this is secure
- No secret in the image, git, or a plain ConfigMap.
- Credentials to AWS are **short-lived** (STS), per-pod, and scoped by the IAM
  policy (only this project's SSM paths + secrets).
- At rest everything is KMS-encrypted; in transit to Aurora it's `sslmode=require`.

### Why DATABASE_URL uses the Aurora **writer** endpoint (not RDS Proxy)
RDS Proxy rejects Prisma's TLS handshake on Aurora PostgreSQL 17 (`P1001`). The
writer endpoint works reliably, so `modules/aurora/proxy.tf` builds the URL from
`aws_rds_cluster.primary.endpoint`. (The `#` in the password is URL-encoded as
`%23`, else Prisma misparses the port.)

---

## 7. IAM / RBAC / network security — layered defence

### 7.1 IAM (AWS-level identity)
- **Cluster/node roles** (`modules/iam`): let EKS manage the cluster and nodes.
- **IRSA roles** (`modules/iam-irsa`): per-workload least privilege.
  - `ecommerce-services-role` — backend pods: read this project's SSM + Secrets
    Manager, publish SNS, send SES, pull ECR, `kms:Decrypt`/`GenerateDataKey`
    via secretsmanager/ssm/**sns**. (The SNS entry is required because login
    publishes `USER_LOGIN_SUCCESS` to a KMS-encrypted SNS topic — missing it =
    login 500.)
  - `lb-controller-role` — the AWS Load Balancer Controller (manages ALBs).
  - `ebs-csi-role`, `cluster-autoscaler-role`, `secrets-store-csi-role` — each
    scoped to its job.
- **DR note:** IRSA roles are **OIDC-bound per cluster**. Each EKS cluster has its
  own OIDC provider, so the DR cluster needs its own `-dr-services-role` whose
  trust policy trusts the us-west-2 OIDC issuer. Reusing the primary role in DR
  causes `AssumeRoleWithWebIdentity AccessDenied`.

### 7.2 Kubernetes RBAC (cluster-level identity)
- **ServiceAccount** `ecommerce-services-sa` is the identity all backend pods run
  as; it carries the IRSA annotation that bridges K8s identity → AWS identity.
- RBAC governs what that SA (and human users via the aws-auth/EKS access entries)
  can do inside the cluster. The CSI driver runs under its own SA
  (`secrets-store-csi-driver`) with its own IRSA role.
- **Separation:** pod → AWS access is granted ONLY through the SA's IRSA role, not
  node credentials — so a compromised pod can't use the node's broader permissions.

### 7.3 Network security (VPC-level)
- **Subnet tiers:** public (ALBs, NAT), private (EKS nodes, Redis), database
  (Aurora). Pods and DB are never in public subnets.
- **Security groups** are the real firewall:
  - Aurora SG allows **5432 only from the EKS node SG** (the auto-created cluster
    SG) and the bastion. Nothing else can reach the DB. (Getting this source SG
    wrong = pods "Can't reach database server" even though the DB is healthy —
    a bug we hit after rearranging SGs.)
  - Redis SG allows **6379 only from EKS nodes**.
- **WAF** sits in front of the external ALB (OWASP top-10 rules) — filters
  malicious requests before they reach the app.
- **TLS** at the ALB (ACM); `sslmode=require` to Aurora.
- Different VPC CIDRs per region (10.1/16 primary, 10.2/16 DR) so they could peer
  without overlap.

---

## 8. The ingress files — how traffic is designed

Two ALBs, two ingress objects (`03-Kubernetes/`):

### External ingress (`frontend/ingress.yaml`) — internet-facing
- `scheme: internet-facing`, `target-type: ip` (routes straight to pod IPs).
- `group.name: external-alb-group` — lets multiple ingresses share ONE ALB
  (cost + simplicity).
- Health check path `/`, success code 200.
- Stickiness (lb_cookie, 24h) so a user keeps hitting the same pod (session
  affinity).
- `subnets:` annotation is **patched per-region** by `02-deploy-app.sh` from the
  real public subnet IDs — this is why using the wrong region's subnets gives
  `InvalidSubnetID.NotFound`. (The deploy script renders this to a temp file so
  the source keeps its placeholder and each region gets its own subnets.)
- HTTPS: add `certificate-arn` + `listen-ports [{HTTP:80},{HTTPS:443}]` +
  `ssl-redirect: 443` once the ACM cert is wired.
- Routes `/` → `frontend-service`.

### Internal ingress (`services/ingress-internal.yaml`) — private
- `scheme: internal` — only reachable inside the VPC.
- Path-based routing to each backend:
  `/api/users`→user-service:4001, `/api/products`→product-service:4002,
  `/api/cart`→cart-service:4003, `/api/orders`→order-service:4004, etc.
- The **frontend never calls backends directly.** Next.js middleware
  (`frontend/middleware.ts`) proxies every `/api/*` request at runtime to
  `INTERNAL_API_URL` (the internal ALB DNS, injected from the `ecommerce-config`
  ConfigMap). This keeps backends private and avoids CORS.

### Why middleware proxy instead of Next.js rewrites
Rewrites are baked at **build time**; `INTERNAL_API_URL` is only known at
**runtime** (K8s ConfigMap). Build-time rewrites always saw `undefined` →
`localhost` → connection refused. Middleware reads `process.env.INTERNAL_API_URL`
on every request, so it always uses the live value. (One local exception:
`/api/region` is served by the frontend itself for DR visibility, not proxied.)

---

## 9. Disaster recovery — what we built and demonstrated

### Design: warm standby, Aurora Global Database
- **Primary** us-east-1 serves all traffic. **DR** us-west-2 runs the same EKS +
  app, with Aurora as a **read-only secondary** replicating from primary (<1s lag).
- **Route53 failover records:** PRIMARY (us-east-1 ALB) with a health check,
  SECONDARY (us-west-2 ALB). If primary is unhealthy, Route53 serves SECONDARY.

### Two independent failover switches (important)
1. **Traffic failover (automatic):** Route53 health check / ALB target health. If
   the primary ALB has no healthy targets (or the health check fails), Route53
   routes the domain to the DR ALB. This is automatic.
2. **Database write failover (manual, deliberate):** `aws rds
   failover-global-cluster` promotes the DR Aurora secondary to writer. This is
   NOT automatic — auto-promoting a DB risks split-brain on a transient blip, so
   it's a human decision.

### What we demonstrated
- Scaled the primary frontend to 0 → external ALB lost all healthy targets →
  with `evaluate_target_health = true` on the primary record, Route53 marked
  primary unhealthy → `pip-ecommerce.com` resolved to the **us-west-2 DR ALB IPs**
  → DR region served the app. Restored by scaling the frontend back to 1.
- **Lesson learned (documented):** on the PRIMARY failover record, `evaluate_
  target_health=true` is what makes "scale frontend to 0" trigger failover. If you
  instead want the explicit Route53 health check to drive it, you'd set it false
  and fail the health check (e.g. change its probe port). The two methods are
  mutually exclusive — pick one.
- **DR limitation (warm standby):** no DR ElastiCache and no us-west-2 ACM cert in
  the demo, so DR served HTTP and Redis-backed features (cart/session) degrade
  until a full DR build. Core browse + (after DB promotion) login work.

---

## 10. CI/CD, GitOps, and rollback

> Jenkins pipeline files are **[DESIGN]** (the `04-Jenkins/ci-pipeline` and
> `infra-pipeline` folders are scaffolding). ArgoCD manifests **exist**
> (`03-Kubernetes/argocd/`) and define the GitOps flow below.

### 10.1 The GitOps flow (ArgoCD — real manifests)
Defined in `03-Kubernetes/argocd/ecommerce-app.yaml`:
1. CI builds a new image, pushes to ECR, bumps the image tag in the K8s manifests,
   commits to a release branch, opens a PR.
2. A human reviews + merges to `main`.
3. **ArgoCD** polls `main` (every ~3 min), detects the manifests changed, compares
   live cluster vs git, and **syncs** — rolling out the new pods.
4. `syncPolicy.automated`: `prune: true` (delete removed resources),
   `selfHeal: true` (revert manual `kubectl` edits — git is the single source of
   truth). `revisionHistoryLimit: 10` keeps history for rollback.
5. ArgoCD health checks confirm success → Slack notification.

**Why GitOps:** the cluster's desired state lives in git. Every change is a
reviewed commit; drift is auto-corrected; rollback = revert a commit.

### 10.2 Current deployment strategy — `Recreate`
The service deployments use `strategy.type: Recreate` (seen in
`user-service/deployment.yaml`). This stops all old pods before starting new ones
— simple and avoids two schema versions hitting the DB at once, at the cost of a
short downtime window per deploy. Suitable for this project's scale.

### 10.3 How to roll back a bad version (immediate)

**Fastest — Kubernetes native rollback (no rebuild):**
```bash
# See rollout history
kubectl rollout history deployment/user-service-deployment -n ecommerce
# Roll back to the previous revision instantly
kubectl rollout undo deployment/user-service-deployment -n ecommerce
# Or to a specific revision
kubectl rollout undo deployment/user-service-deployment -n ecommerce --to-revision=3
```
This re-points the deployment at the previous ReplicaSet (previous image) — seconds.

**GitOps rollback (clean, auditable):**
```bash
git revert <bad-commit>   # revert the manifest/image-tag change
git push                  # ArgoCD detects the revert and syncs the old version
```
Or in the ArgoCD UI: **History and Rollback** → pick the previous synced revision
(ArgoCD keeps 10). Because `selfHeal` is on, you revert in git — don't `kubectl`
edit, or ArgoCD will undo your manual change.

**Image-tag pin:** if images are tagged per release (`v1.2.3`), rollback is just
setting the manifest image back to the previous tag and letting ArgoCD sync.

### 10.4 Advanced release strategies **[DESIGN]**
These are not yet wired but are the natural next step (would use Argo Rollouts):

- **Blue/Green:** run the new version ("green") alongside the current ("blue") on a
  separate target group. Flip the ALB/Service selector to green once verified.
  Instant rollback = flip back to blue. Needs 2× pods briefly.
- **Canary:** shift a small % of traffic (e.g. 10%) to the new version, watch
  metrics/errors, then ramp 25→50→100%. Auto-rollback if error rate/latency
  SLOs breach. Argo Rollouts + the ALB's weighted target groups implement this.
- **Why not today:** `Recreate` is simpler and the cluster is small. Blue/green or
  canary matter once you need zero-downtime + automated safety gates.

**DR vs app-version rollback — the parallel the question draws:**
- *DR failover* recovers from a **region/infra** outage (Route53 → DR region).
- *Rollback* recovers from a **bad app version** (`kubectl rollout undo` / git
  revert → previous image). Same philosophy (fast reversible recovery), different
  layer. Both are rehearsed, both are reversible, neither destroys data.

---

## 11. Idempotency & "one apply per region" (operational design)

- **DR secrets** are created in us-west-2 by Terraform (`dr-app-secrets.tf`) so DR
  pods never miss `jwt-secret`, `redis/auth-token`, etc. (regional services).
- **ALB auto-discovery** (`alb-discovery.tf`) reads the live ALB hostname from the
  ingress so Route53 never points at a stale/dead ALB after a rebuild.
- **Pre-apply cleanup** (`00-pre-apply-cleanup.sh`) deletes survivors (CloudWatch
  log groups, orphaned WAF buckets) so a fresh apply doesn't hit "already exists".
- **AWS provider pinned** `~> 5.60` so a provider major bump can't force the WAF
  S3 bucket to replace (which caused `BucketAlreadyExists`).

---

## 12. One-line answers (interview rapid-fire)

- **Why JWT?** Stateless proof of user identity across services, no server session.
- **Why a separate internal key?** JWT proves a user; the internal key proves a
  *service* for private `/internal/*` endpoints.
- **Why Redis?** Offload Aurora for the hottest reads (cart, session) and make
  cross-replica correctness possible (rate limits, idempotency).
- **Why alias A-record, not CNAME?** CNAME is illegal at the apex; ALB has no fixed
  IP; alias A-record returns the ALB's current IPs and auto-follows changes.
- **Why ACM?** Browser-trusted auto-renewing TLS; attached to the ALB; regional
  (DR needs its own us-west-2 cert).
- **How do pods get DB creds?** IRSA (SA→IAM via OIDC) + Secrets Store CSI driver
  fetches KMS-encrypted SSM/Secrets-Manager values and mounts them; no secret in
  the image.
- **How to roll back fast?** `kubectl rollout undo` (seconds) or git-revert → ArgoCD
  re-syncs the previous version.
- **How does failover work?** Route53 PRIMARY/SECONDARY records + health/target
  checks route the domain to the DR ALB automatically; DB promotion is a separate
  manual step.
