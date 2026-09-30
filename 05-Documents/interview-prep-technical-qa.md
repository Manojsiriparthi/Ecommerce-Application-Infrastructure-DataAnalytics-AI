# Technical Interview Prep — Q&A
## pip-project-ecommerce — Defend Every Design Decision

This document answers the technical questions you'll be asked about the
architecture, infrastructure, security, networking, and failure handling.
Each answer explains WHAT, WHY, the PROBLEM it solves, and ALTERNATIVES.

---

# SECTION A — Pod-to-Pod & Service Communication

## Q: How do the frontend and backend pods talk to each other?
The browser calls a relative path `/api/users/login`. The Next.js frontend pod
receives it, and its middleware forwards it server-side to the **Internal ALB**.
The Internal ALB path-routes `/api/users` → user-service pod (ClusterIP service
→ pod IP). The browser NEVER talks to backend pods directly.

## Q: How do backend services talk to each other? (e.g. order → payment)
Service-to-service calls go through the Internal ALB too, OR directly via
Kubernetes ClusterIP DNS (`http://payment-service:4005`). In our code,
order-service calls payment-service to verify payment before creating an order,
using the internal service URL + an `x-internal-key` header for authentication.

## Q: Why an internal service key for service-to-service calls?
Backend services expose `/internal/*` endpoints (e.g. `/internal/users/:id`) that
should ONLY be callable by other services, never by users. Each internal call
includes header `x-internal-key: <shared-secret>`. The receiving service checks
it and returns 403 if wrong. This prevents a user's JWT from accessing internal
endpoints.

## Q: What is a ClusterIP service and why use it?
A ClusterIP is a stable virtual IP + DNS name inside the cluster. Pods are
ephemeral (IPs change on restart). The service gives a fixed name
(`user-service:4001`) that always routes to healthy pods via the selector
`app: user-service, tier: backend`.

---

# SECTION B — Ingress & Deployment File Design

## Q: Explain your Ingress design.
Two Ingress resources, each creates an ALB via the AWS Load Balancer Controller:

**External Ingress** (`frontend/ingress.yaml`):
- `scheme: internet-facing` — public ALB in public subnets
- `target-type: ip` — registers pod IPs directly (not NodePort)
- `group.name: external-alb-group` — shares one ALB
- Routes `/` → frontend-service:80
- Health check path `/`, WAF attached, subnets from public subnet IDs

**Internal Ingress** (`services/ingress-internal.yaml`):
- `scheme: internal` — private ALB in private subnets, no public IP
- Path routing: `/api/users`→4001, `/api/products`→4002, etc.
- Health check path `/health` per service

## Q: Why target-type: ip instead of instance?
`ip` mode registers pod IPs directly as ALB targets. Benefits:
- Traffic goes straight to the pod (one less network hop than NodePort)
- Works with Fargate
- Health checks hit the actual pod, not the node
Requires the ALB to have a network interface in the pod's subnet — that's why we
have a public EKS node (provides the ENI in the public subnet).

## Q: Explain your Deployment design.
Each service Deployment has:
- `replicas: 1` (scaled for demo; HPA can scale up)
- `strategy: type: Recreate` — old pod dies before new one starts (chosen because
  limited pod slots on t3.small; RollingUpdate would deadlock waiting for capacity)
- `serviceAccountName: ecommerce-services-sa` — for IRSA
- Secrets Store CSI volume mount — injects secrets
- `resources: requests 64Mi/50m, limits 256Mi/200m` — right-sized for t3.small
- `livenessProbe` + `readinessProbe` on `/health` — K8s restarts unhealthy pods,
  only sends traffic to ready ones
- `podAntiAffinity` — spreads replicas across nodes for HA

## Q: Liveness vs Readiness probe difference?
- **Readiness** — "can this pod receive traffic yet?" If it fails, the pod is
  removed from the service (no traffic) but NOT restarted. Used during startup.
- **Liveness** — "is this pod alive or hung?" If it fails, K8s RESTARTS the pod.
Both hit `/health`. Readiness has shorter delays (10s), liveness longer (30s).

## Q: Why Recreate strategy and not RollingUpdate?
On t3.small nodes there are limited pod slots. RollingUpdate creates the NEW pod
BEFORE killing the old one — but there's no free slot, so the new pod stays
Pending forever (deadlock). Recreate kills the old pod first, freeing the slot.
Trade-off: brief downtime during deploy (acceptable for this scale).

---

# SECTION C — IAM & IRSA (most-asked security topic)

## Q: Why IRSA instead of putting AWS keys in the pod?
IRSA (IAM Roles for Service Accounts) gives pods TEMPORARY, auto-rotating AWS
credentials via the EKS OIDC provider. No long-lived access keys stored anywhere.
If a pod is compromised, the attacker gets short-lived creds scoped to only what
that role allows — not permanent account-wide keys.

## Q: Walk me through how IRSA actually works (they WILL ask this).
1. The pod uses ServiceAccount `ecommerce-services-sa`
2. That SA is annotated: `eks.amazonaws.com/role-arn: <IAM role ARN>`
3. EKS injects a signed JWT token (from the cluster's OIDC provider) into the pod
4. The AWS SDK in the pod calls STS `AssumeRoleWithWebIdentity`, presenting the token
5. STS validates the token against the OIDC provider's trust policy
6. STS returns TEMPORARY credentials (valid ~1 hour, auto-refreshed)
7. Pod uses those creds to call AWS (read SSM, publish SNS)

## Q: "Secrets are already in AWS Secrets Manager/SSM. Why do we still need
##    IRSA + the CSI driver? Why the extra step?"
This is a great question and here's the precise answer:
- Secrets Manager/SSM STORE the secret securely. But the pod still needs
  PERMISSION to READ them, and a MECHANISM to get them into the pod.
- IRSA provides the PERMISSION (temporary credentials scoped to read that secret).
- The Secrets Store CSI Driver provides the MECHANISM (mounts the secret as a
  file / syncs to a K8s Secret → env var).
- Without IRSA: the pod has no AWS identity, so Secrets Manager returns
  AccessDenied. Without the CSI driver: nothing fetches the secret into the pod.
- The alternative (hardcoding the secret in the pod's env/image) defeats the whole
  purpose of storing it securely in AWS. IRSA + CSI keeps the secret in AWS,
  fetched just-in-time with a temporary identity.

## Q: Why is the IRSA temporary token better than a static token?
- Static token: if leaked, valid forever until manually rotated → big blast radius
- Temporary token: expires in ~1 hour, auto-rotated, scoped to one role → small
  blast radius. Even if leaked, it's useless within the hour.

## Q: Why different IAM roles for primary vs DR clusters?
IRSA role trust policies are bound to ONE cluster's OIDC provider URL. A DR pod's
token comes from the DR OIDC endpoint, which the primary's role rejects. So DR
needs its own IRSA roles (`iam_irsa_dr`). Plain service roles (cluster/node role)
have no OIDC binding, so those ARE reused across regions.

## Q: What's the principle behind your IAM policies?
Least privilege. Each role gets ONLY the actions on ONLY the resources it needs.
Example: the EBS-backup Lambda can `CreateSnapshot` on any volume but can only
`DeleteSnapshot` on snapshots TAGGED by it (`ManagedBy=lambda-ebs-backup`) —
condition-scoped so it can never delete someone else's snapshot.

---

# SECTION D — JWT Tokens

## Q: Why JWT and how does it work here?
JWT (JSON Web Token) is a signed token proving who the user is, WITHOUT the server
storing sessions. Flow:
1. User logs in → user-service verifies email/phone/password
2. user-service signs a JWT with the shared `JWT_SECRET`, containing `{sub: userId, email}`, expires in 1 hour
3. Browser stores it (localStorage), sends it as `Authorization: Bearer <token>` on every request
4. ANY service verifies it locally using the same `JWT_SECRET` — no call to user-service needed

## Q: Why is JWT better than server-side sessions here?
- **Stateless** — any service can verify without a shared session store
- **Scalable** — no session DB/Redis lookup per request
- **Microservice-friendly** — cart-service verifies the token itself; doesn't
  depend on user-service being up

## Q: What's the downside of JWT and how do you handle it?
- Can't revoke before expiry (it's self-contained). Mitigation: short 1-hour
  expiry. For instant revocation you'd add a Redis blocklist (we have Redis ready).
- If `JWT_SECRET` leaks, all tokens are forgeable. Mitigation: secret stored in
  SSM SecureString (KMS-encrypted), rotatable via the secrets-rotation Lambda.

## Q: Why is JWT_SECRET shared across all services?
So any service can verify a token independently. It's stored once in SSM, fetched
by each pod via IRSA + CSI driver. Rotating it invalidates all sessions (users
re-login) — done during low-traffic windows by the rotation Lambda.

---

# SECTION E — Secrets: Secrets Manager vs SSM

## Q: When do you use Secrets Manager vs SSM Parameter Store?
- **Secrets Manager** — raw standalone secrets needing rotation support
  (DB master credentials, Redis auth token). Costs more, supports rotation lambdas.
- **SSM SecureString** — config values that happen to be sensitive
  (DATABASE_URL connection string, JWT secret, internal key). Cheaper, KMS-encrypted.
Rule of thumb: raw secret needing rotation → Secrets Manager. Config with a secret
inside → SSM SecureString.

## Q: Why is the whole DATABASE_URL in SSM, not just the password?
The URL is a config value (host, port, db name, sslmode) that CONTAINS the
password. Storing the assembled URL is simpler than storing pieces and building
it in code — one fetch, one env var. It's a SecureString so the whole thing is
KMS-encrypted.

---

# SECTION F — WAF Design

## Q: Why WAF and what does it protect against?
WAF inspects HTTP requests at the ALB BEFORE they reach the app. It blocks:
- SQL injection (`' OR 1=1--`)
- XSS (`<script>` payloads)
- Rate-based attacks (too many requests from one IP → block)
- Known-bad IPs and common OWASP exploits (AWS managed rule sets)

## Q: Where is WAF attached and why there?
Attached to the EXTERNAL ALB (internet-facing). That's the only internet entry
point, so it's where attacks arrive. The internal ALB needs no WAF — it's private,
only reachable from inside the VPC by trusted frontend pods.

## Q: How do you know WAF is working?
Blocked requests go to CloudWatch metric `BlockedRequests` + logged to S3. We have
an alarm `waf-blocked-spike` that fires if > 1000 blocks in 5 min (possible attack).
You can test: send a `?id=1' OR '1'='1` request and get a 403.

---

# SECTION G — Route53 + ACM Certificate

## Q: What problem does Route53 solve here?
1. **DNS** — maps `pip-ecommerce.com` → the ALB (users can't type an ALB's random
   DNS name)
2. **Failover** — health-checks the primary ALB; auto-routes to DR if it fails
3. **Domain validation** — hosts the CNAME records ACM needs to issue the cert

## Q: A record vs CNAME — explain.
- **A (alias) record** — maps a name to an IP (or an AWS resource like an ALB).
  Used for `pip-ecommerce.com` → ALB. Works on the root/apex domain.
- **CNAME** — maps a name to ANOTHER name. Used for ACM validation
  (`_acme-challenge...` → AWS validation string). CANNOT be used on the apex
  domain — that's why AWS invented alias A records.

## Q: How does ACM certificate validation work?
1. ACM issues a cert request for `pip-ecommerce.com` + `*.pip-ecommerce.com`
2. ACM gives us DNS validation records (CNAMEs)
3. Terraform auto-creates those CNAMEs in Route53
4. ACM checks the CNAMEs exist (proves we own the domain) → issues the cert
5. Cert auto-renews before expiry (AWS-managed, no manual renewal)

## Q: Why DNS validation not email validation?
DNS validation auto-renews forever (the CNAME stays in place). Email validation
requires a human to click a link every renewal. DNS is hands-off.

## Q: Where is the cert used?
Attached to the External ALB HTTPS listener (port 443). The ALB terminates TLS —
traffic is HTTPS from browser→ALB, then plain HTTP ALB→pods inside the trusted VPC.

---

# SECTION H — S3 Bucket Policy, Lifecycle, Retention

## Q: Explain your S3 logs bucket design.
One bucket `pip-project-ecommerce-logs-prod-<account>`:
- **Encryption** — SSE-KMS with our KMS key
- **Versioning** — on (tamper evidence — can't silently overwrite logs)
- **Public access** — fully blocked (all 4 block settings on)
- **Bucket policy** — allows ONLY the ALB service account + WAF Firehose to write
- **Lifecycle** — transition to Glacier after 365 days, expire after 730 days

## Q: Why the bucket policy restricts to specific principals?
The ALB writes access logs using the regional ELB service account
(`127311923021` for us-east-1). The policy allows ONLY that account to `PutObject`
into `alb-logs/*`, and WAF Firehose into `waf-logs/*`. Nobody else can write —
prevents log tampering/injection.

## Q: What's the lifecycle for and why those numbers?
Cost control + compliance. Recent logs (hot) stay in S3 Standard for fast access.
After 365 days → Glacier (10x cheaper, rarely accessed). After 730 days → deleted
(compliance retention met). Application logs in CloudWatch: 30 days. Audit logs: 90 days.

---

# SECTION I — SNS / SQS

## Q: What do you use SNS for?
Async notifications. When a user registers/pays/orders, the service publishes an
event to an SNS topic and moves on (doesn't wait). notification-service subscribes
and sends email (SES) / SMS. Decouples the user action from the slow notification.

## Q: SNS vs SQS — when which?
- **SNS** — pub/sub, push, one-to-many. One event → all subscribers. Used for
  fan-out notifications. If a subscriber is down, that message is lost (unless
  paired with SQS).
- **SQS** — queue, pull, one-to-one, durable. Messages persist until consumed.
  Used for guaranteed work processing (e.g. order fulfillment queue).
Best practice for critical events: SNS → SQS (fan-out + durability). We use SNS
for notifications; SQS could be added for guaranteed order processing.

## Q: What happens if notification-service is down when an event fires?
With plain SNS, the message could be lost. Production fix: subscribe an SQS queue
to the SNS topic — messages wait in the queue until notification-service recovers.
This is the SNS+SQS fan-out pattern.

---

# SECTION J — CloudWatch, Monitoring, Alarms

## Q: What do you monitor and how?
- **26 alarms** — Aurora (CPU, memory, connections, replica lag), Redis, ALB
  (5xx, 4xx, latency p99, unhealthy hosts), EKS (node CPU/memory, pod restarts),
  WAF blocks, NAT errors, GuardDuty, Route53 health, + 4 ML anomaly-detection alarms
- **3 dashboards** — Infrastructure, Application, Business
- **Logs Insights queries** — error-rate trend, slow requests, DB errors
- **Alarms → SNS → Lambda → Slack/PagerDuty**

## Q: Static threshold vs anomaly detection alarm?
- **Static** — "CPU > 80%". Simple but noisy (weekends have low traffic) and
  misses gradual drift.
- **Anomaly** — `ANOMALY_DETECTION_BAND` learns the normal pattern per time-of-day
  and alerts on deviation. Catches "unusual for a Tuesday 3pm" that static misses.

## Q: How do alarms reach a human?
Alarm → SNS topic → sns-to-slack Lambda → Slack webhook (and PagerDuty for
HIGH/CRITICAL). The Lambda formats a color-coded message with a link to CloudWatch.

---

# SECTION K — Networking & Security Design

## Q: Explain your subnet design (3 tiers).
- **Public subnets** (10.1.1-3.0/24) — External ALB + public EKS node. Route to
  Internet Gateway. Only internet-facing things.
- **Private subnets** (10.1.11-13.0/24) — worker nodes (all app pods), internal
  ALB, ElastiCache. Route to NAT Gateway for outbound (pull images) but no inbound
  from internet.
- **Database subnets** (10.1.21-23.0/24) — Aurora only. Most isolated, no internet
  route at all.
Three AZs for high availability.

## Q: Why is the database in its own subnet tier?
Defense in depth. Even if the app tier is compromised, the DB subnet has no
internet route and its security group only allows 5432 from the EKS node SG. An
attacker can't exfiltrate data to the internet from there.

## Q: Explain your security group chain.
- ALB SG: allows 80/443 from internet (0.0.0.0/0)
- EKS node SG: allows traffic from ALB SG only
- Aurora SG: allows 5432 from EKS node SG only
- Redis SG: allows 6379 from EKS node SG only
Each layer only accepts traffic from the layer above it — no direct internet→DB path.

## Q: What was the EKS security group gotcha you hit?
EKS creates TWO SGs: the one we define, AND an auto-created cluster SG attached to
all nodes. Our Aurora rule only allowed the first, but pods run under the second →
connection timeouts. Fix: a standalone `aws_security_group_rule` allowing the
auto-created SG (`cluster_security_group_id`) to reach Aurora on 5432.

---

# SECTION L — Failure Handling (503, 404, timeouts)

## Q: You get a 503 from the app. How do you debug?
503 = Service Unavailable, usually the ALB has no healthy targets.
1. `kubectl get pods -n ecommerce` — are pods Running?
2. `kubectl describe pod <pod>` — CrashLoopBackOff? OOMKilled?
3. `kubectl logs <pod>` — application error?
4. Check ALB target group health in AWS console
5. Check readiness probe — pod may be up but not "ready"
Common cause: pod failing readiness probe on `/health`, so ALB pulls it out.

## Q: You get a 404 on /api/users/login. How do you debug?
404 = route not found. In our case we hit this exact bug:
1. Check the Internal ALB listener rules — is `/api/users` mapped to user-service?
2. Check the frontend code — was it calling `/api/users/api/users/login`
   (double path)? We had this bug — fixed the API base path.
3. Check the ingress path routing matches what the service expects.

## Q: Login fails with "Unable to connect". How do you debug?
This was a real bug chain we solved:
1. `kubectl exec frontend -- env | grep INTERNAL_API_URL` — is it set correctly?
   (We found it was corrupted with log output — fixed the wait_alb function)
2. Test the internal ALB directly: `wget http://<internal-alb>/api/users/health`
3. Check DB connectivity from the pod (Prisma P1001 = can't reach DB)
4. Check the SG rule (EKS node SG → Aurora)
5. Check DATABASE_URL uses writer endpoint not proxy, and `#` is `%23`

## Q: How does the app survive a pod crash?
- Liveness probe detects the hung/dead pod → K8s restarts it
- Readiness probe removes it from the ALB during restart (no traffic to broken pod)
- Deployment ensures `replicas` count → replaces crashed pods
- podAntiAffinity spreads replicas across nodes → one node dying ≠ full outage

## Q: How does the app survive a whole REGION failure?
1. Route53 health check on primary ALB fails (3× 30s = 90s)
2. Route53 stops returning primary IP, returns DR IP
3. Promote DR Aurora secondary to writable (`failover-global-cluster`)
4. Scale up DR EKS nodes
5. Traffic now served from us-west-2 with all data (replicated < 1s)
RTO < 2 min, RPO < 1 sec.

---

# SECTION M — Quick-fire likely questions

**Q: Why EKS not ECS?** — EKS = standard Kubernetes (portable, huge ecosystem,
team K8s skills transfer). ECS is AWS-only. We chose portability.

**Q: Why Aurora not RDS?** — Aurora replicates cross-region in < 1s (RDS: minutes),
auto-scales storage, faster failover. Global Database is purpose-built for our DR.

**Q: Why 3 nodes?** — One per AZ. If an AZ fails, two remain. Minimum for HA.

**Q: How do you do zero-downtime deploys?** — RollingUpdate (with enough capacity)
or blue-green. Currently Recreate due to node capacity; with more nodes, switch to
RollingUpdate + surge.

**Q: What's your RTO and RPO?** — RTO < 2 min (Route53 failover), RPO < 1 sec
(Aurora Global DB replication).

**Q: How are secrets rotated?** — secrets-rotation Lambda on EventBridge schedule
rotates DB password + JWT secret in SSM/Secrets Manager, then pods restart to
pick up new values.

**Q: How do you prevent one service's DB access from touching another's data?** —
Each service has its own database (user_db, product_db, etc). Separation at the
DB level, not just table level.


---

# SECTION N — More Project-Specific Q&A (short answers)

## Networking Design

**Q: Why 3 availability zones?**
One AZ can fail entirely (power, network). With 3 AZs, losing one still leaves two
running. It's the AWS-recommended minimum for production HA.

**Q: Why separate public/private/database subnets?**
Defense in depth. Public holds only internet-facing things (ALB). Private holds
app pods (no direct internet). Database is most isolated (no internet route at all).

**Q: How do private pods pull Docker images without internet access?**
Through the NAT Gateway. Private subnets route outbound traffic via NAT (for
pulling images, calling AWS APIs) but block all inbound from the internet.

**Q: Why NAT Gateway and not NAT Instance?**
NAT Gateway is AWS-managed, auto-scales, highly available. NAT Instance is a
self-managed EC2 you have to patch and can become a bottleneck. NAT GW is standard.

**Q: What is the VPC CIDR and why plan it?**
Primary 10.1.0.0/16, DR 10.2.0.0/16, dev 10.0.0.0/16 — non-overlapping so we can
peer them later without IP conflicts. /16 gives 65k IPs, plenty for pods.

**Q: How does an internal ALB differ from external?**
Scheme: internal = no public IP, lives in private subnets, only reachable inside
the VPC. External = internet-facing, public IP, in public subnets.

## Security Design

**Q: How do you keep the database unreachable from the internet?**
It's in database subnets with no internet route, and its security group only
allows port 5432 from the EKS node security group. No public path exists.

**Q: What is defense in depth in this project?**
Multiple layers: WAF → SG on ALB → SG on nodes → SG on DB → private subnets →
KMS encryption. An attacker must break every layer, not just one.

**Q: How is data encrypted?**
At rest: KMS encrypts Aurora, Redis, S3, EBS volumes, SSM SecureStrings. In
transit: HTTPS (ACM cert) browser→ALB, TLS to Aurora (sslmode=require).

**Q: What does GuardDuty do here?**
Threat detection — watches for compromised nodes, crypto-mining, unusual API
calls, data exfiltration. Findings trigger a CloudWatch alarm.

**Q: How do you rotate secrets without downtime?**
The secrets-rotation Lambda updates SSM/Secrets Manager on schedule, then pods
restart (Recreate) to pick up new values during a low-traffic window.

**Q: Why encrypt EBS volumes on nodes?**
If a disk is physically recovered or a snapshot leaks, the data is unreadable
without the KMS key. Compliance requirement + defense in depth.

## EKS / Kubernetes Design

**Q: What are the required subnet tags for EKS?**
`kubernetes.io/role/elb=1` (public, for external ALBs), `kubernetes.io/role/
internal-elb=1` (private, internal ALBs), `kubernetes.io/cluster/<name>=shared`.

**Q: How does the app scale under load?**
HPA scales pods based on CPU/memory. Cluster Autoscaler adds nodes when pods can't
be scheduled. Two layers: pod-level and node-level autoscaling.

**Q: What happens if a node dies?**
K8s reschedules its pods onto healthy nodes. podAntiAffinity spread the replicas,
so one node dying doesn't take down a whole service. Cluster Autoscaler replaces it.

**Q: Why one ServiceAccount for all backend services?**
They all need the same AWS permissions (read SSM/Secrets, publish SNS). One IRSA
role is simpler than six. Each service's DB access is isolated at the DB level.

**Q: How do secrets get into a pod securely?**
SecretProviderClass defines which SSM/Secrets Manager values to fetch. The Secrets
Store CSI driver fetches them using the pod's IRSA role, syncs to a K8s Secret,
pod reads as env var. Secret never sits in the image or git.

**Q: What is a ConfigMap vs a Secret?**
ConfigMap = non-sensitive config (region, Redis host, internal ALB DNS). Secret =
sensitive (DATABASE_URL, JWT). Both injected as env vars but Secrets are handled
more carefully (from AWS via CSI driver).

## Implementation Details

**Q: Why Prisma as the ORM?**
Type-safe queries, easy migrations (`prisma db push`), good PostgreSQL support.
Each service has its own schema.prisma defining only its tables.

**Q: How were the database tables created?**
`prisma db push` run inside each service pod (via 01-setup-databases.sh), which
reads the schema and creates tables in that service's database.

**Q: Why does each service have its own database?**
Microservice isolation — user-service can't accidentally read payment data. A
schema change in one service doesn't affect others. Clear ownership boundaries.

**Q: How does the frontend know the internal ALB address?**
It's stored in a ConfigMap (`internal_alb_dns`), injected as env var
`INTERNAL_API_URL`. The Next.js middleware reads it at runtime to proxy /api calls.

**Q: What is the health check endpoint?**
Each service exposes `/health` returning 200 + `{status: ok}`. The ALB and K8s
probes hit it. If it fails, the pod is pulled from rotation / restarted.

## Failover & DR

**Q: What is warm standby vs hot vs cold?**
Cold = rebuild from backup (slow, cheap). Warm = DR runs minimal, scale up on
failover (our choice — balance). Hot = full duplicate always running (fast, expensive).

**Q: How long does failover take (RTO)?**
< 2 minutes. Route53 health check fails after 90s (3×30s), DNS TTL 60s, so clients
switch within ~2 min. Aurora promotion + node scale-up happen in parallel.

**Q: How much data could you lose (RPO)?**
< 1 second. Aurora Global Database replicates continuously with sub-second lag.

**Q: How do you test failover without a real outage?**
`05-dr-failover-test.sh stop-alb` scales the primary frontend to 0 → ALB unhealthy
→ Route53 fails over to DR. Or disable the health check directly. Then restore.

**Q: After failover, how do you fail back to primary?**
Restore the primary app, let Aurora re-sync the primary as a secondary, then
failover the Global Database back to us-east-1 during a maintenance window.

## Cost & Operations

**Q: How do you keep cost under $5000/month?**
Small right-sized nodes (t3.small), warm-standby DR (not full duplicate), S3
lifecycle to Glacier, single NAT per region, autoscaling down when quiet.

**Q: What's the most expensive component?**
Aurora (r6g.large writer + 2 readers + DR replica) and NAT Gateway data
processing. Monitored via cost alarms.

**Q: How do you get alerted on problems?**
26 CloudWatch alarms → SNS → Lambda → Slack (and PagerDuty for HIGH/CRITICAL).
Anomaly-detection alarms catch unusual patterns static thresholds miss.

## Common "how would you handle" questions

**Q: How would you handle a sudden 10x traffic spike?**
HPA scales pods on CPU, Cluster Autoscaler adds nodes, ALB spreads load. WAF rate
limiting blocks abusive IPs. Redis (when wired) caches hot reads to protect the DB.

**Q: How would you handle a database running out of connections?**
Aurora connection alarm fires. Prisma pools connections per pod. If needed, add
RDS Proxy (for a driver that supports it) or increase max_connections parameter.

**Q: How would you do a zero-downtime deployment?**
With enough node capacity, switch from Recreate to RollingUpdate with maxSurge —
new pods come up and pass readiness before old ones drain. Or blue-green.

**Q: How would you debug slow API responses?**
CloudWatch ALB p99 latency alarm + Logs Insights "slow-requests" query. Check
Aurora CPU/connections, check for missing DB indexes, check pod resource limits.

**Q: A deployment broke production. How do you roll back?**
`kubectl rollout undo deployment/<name> -n ecommerce` — reverts to the previous
ReplicaSet. K8s keeps deployment history. Images are tagged so you can pin versions.

**Q: How would you add caching to reduce DB load?**
Wire ElastiCache Redis (already provisioned): cache product catalog + sessions.
Read-through cache: check Redis first, fall back to Aurora, populate Redis.
