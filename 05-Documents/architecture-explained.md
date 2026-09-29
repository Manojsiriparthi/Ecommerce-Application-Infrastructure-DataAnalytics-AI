# Architecture Explained — Every Service, Every Rule, Every Decision

**Project:** pip-project-ecommerce  
**Purpose:** This document explains WHY every AWS service exists, what problem it solves, how every security group rule is configured, and how data flows from a user's click to the database and back.

---
![alt text](image.png)
## Part 1 — The Big Question: Why So Many Services?

Before explaining each service, understand the problem we are solving:

> A user opens your website. Thousands of users might open it at the same time. Their data must be safe. The system must never go down. If one piece fails, the rest must keep working.

Every service we chose solves one specific part of that problem. Nothing is added for show.

---

## Part 2 — Full Workflow: User Clicks "Buy" → What Happens?

```
User's Browser (Mumbai, India)
    │
    │  1. Types: ecommerce-pip.com
    ▼
[Route53] — DNS lookup — returns ALB IP address
    │
    │  2. HTTPS request travels to AWS
    ▼
[WAF] — inspects every packet before it enters your system
    │
    │  3. Clean request allowed through
    ▼
[External ALB] — terminates HTTPS, forwards HTTP to pods
    │
    │  4. Forwards to one of 3 frontend pods (round-robin)
    ▼
[Frontend Pod - Next.js] — renders the page
    │
    │  5. User clicks "Add to Cart"
    │     Frontend calls: POST http://<internal-alb>/api/cart/items
    ▼
[Internal ALB] — routes /api/cart/* to cart-service
    │
    │  6. Forwards to cart-service pod on port 4003
    ▼
[cart-service Pod]
    │  - Verifies JWT token
    │  - Gets DB credentials from Secrets Manager (via CSI driver)
    │  - Checks Redis cache
    │  - Writes to Aurora via RDS Proxy
    │
    │  7. User clicks "Pay"
    ▼
[payment-service Pod]
    │  - Charges the user
    │  - Publishes PAYMENT_SUCCESS event to SNS
    │
    │  8. SNS delivers event to notification-service
    ▼
[notification-service Pod]
    │  - Sends SMS via SNS
    │  - Sends email via SES
    ▼
User receives: "Your order is confirmed" SMS + email
```

---

## Part 3 — Every AWS Service Explained

### Route53 — The Phone Book

**What problem does it solve?**  
Users type `ecommerce-pip.com` — but computers need an IP address, not a name. Route53 translates the name to the ALB's IP address. Without Route53, users would have to type a long ugly AWS URL like `k8s-external-xxxx.us-east-1.elb.amazonaws.com`.

**Extra problem it solves — Disaster Recovery:**  
Route53 checks your primary ALB health every 10 seconds. If it fails 3 times (30 seconds), Route53 automatically switches DNS to point to your DR region ALB. No human action needed. Users are back online in 2 minutes.

**Configuration in this project:**  
- A-record: `ecommerce-pip.com` → External ALB
- Health check: HTTP on the ALB every 10 seconds
- TTL: 60 seconds (how quickly DNS change propagates)

---

### WAF (Web Application Firewall) — The Security Checkpoint

**What problem does it solve?**  
Without WAF, anyone can send malicious requests to your application. Examples:
- SQL Injection: `'; DROP TABLE users; --` in a form field → deletes your database
- XSS: `<script>steal_cookies()</script>` in a comment → steals user sessions
- DDoS: 10,000 requests per second → crashes your server

**WAF sits in front of the External ALB and blocks all of these BEFORE they reach your code.**

**Rules configured:**
1. `AWSManagedRulesCommonRuleSet` — blocks OWASP Top 10 attacks (SQL injection, XSS, etc.)
2. `AWSManagedRulesKnownBadInputsRuleSet` — blocks Log4Shell, SSRF exploits
3. `AWSManagedRulesSQLiRuleSet` — extra SQL injection protection
4. `AWSManagedRulesAmazonIpReputationList` — blocks known bad IPs (botnets)
5. Rate limit: **100 requests per 5 minutes per IP** — prevents any single user from overwhelming the system

**WAF logs everything to S3** — so you can audit what was blocked.

---

### External ALB — The Main Entrance

**What problem does it solve?**  
You have 3 frontend pods. Which one should answer each user's request? The ALB distributes requests evenly across all 3 pods (load balancing). If one pod crashes, the ALB stops sending traffic to it automatically.

**Why ALB (Application Load Balancer) and NOT NLB (Network Load Balancer)?**

| Feature | ALB (Layer 7) | NLB (Layer 4) |
|---------|-------------|-------------|
| WAF can attach | ✅ Yes | ❌ No |
| HTTPS termination | ✅ Yes | ❌ No |
| Path-based routing (/api/users) | ✅ Yes | ❌ No |
| Host-based routing | ✅ Yes | ❌ No |

WAF only works with ALB. Path-based routing (sending `/api/users` to user-service and `/api/products` to product-service) only works with ALB. That's why we use ALB everywhere.

**Security Group rules for External ALB:**

```
INBOUND:
  Port 80  (HTTP)  — from 0.0.0.0/0 (internet) — only to redirect to 443
  Port 443 (HTTPS) — from 0.0.0.0/0 (internet)

OUTBOUND:
  Port 3000 — to EKS worker security group (frontend pods)
  All traffic allowed outbound
```

**Configuration:**  
- Scheme: `internet-facing` (has a public IP, reachable from internet)
- Target type: `ip` (routes directly to pod IPs, not EC2 node IPs)
- HTTPS: ACM certificate handles TLS termination
- Access logs → S3 bucket

---

### Internal ALB — The Internal Highway

**What problem does it solve?**  
The frontend pod needs to call 6 different backend services. Without an Internal ALB:
- Frontend would need to know the IP of every backend pod
- Pod IPs change when pods restart
- Frontend would need to do load balancing itself

With the Internal ALB:
- Frontend always calls one DNS name: `internal-k8s-xxx.us-east-1.elb.amazonaws.com`
- The Internal ALB routes based on path:
  - `/api/users/*` → user-service pods
  - `/api/products/*` → product-service pods
  - `/api/cart/*` → cart-service pods
  - etc.
- If a pod restarts and gets a new IP, the ALB updates automatically

**Why "internal"?**  
The Internal ALB has NO public IP. It only exists inside the VPC. No one on the internet can reach it. This means even if an attacker bypasses the External ALB (somehow), they still cannot directly call your backend services.

**Security Group rules for Internal ALB:**

```
INBOUND:
  Port 80 — from EKS worker security group ONLY (frontend pods)
  
OUTBOUND:
  Port 4001-4006 — to EKS worker security group (backend service pods)
```

---

### EKS (Elastic Kubernetes Service) — The Container Orchestrator

**What problem does it solve?**  
You have 7 applications (1 frontend + 6 services) that need to run simultaneously. Each runs in a Docker container. Someone needs to:
- Start them when they crash
- Restart them automatically
- Scale them up when traffic is high
- Scale them down when traffic is low
- Spread them across 3 AZs so one AZ failure doesn't kill everything

That "someone" is Kubernetes (EKS). It's a system that manages containers automatically.

**Why 3 node groups?**

```
workers (private subnets, t3.small × 3):
  → All application pods run here
  → Private subnets = no public IP = internet cannot reach pods directly

public (public subnets, t3.micro × 1):
  → Required for ALB ip-mode target routing
  → ALB needs ENIs (network interfaces) in public subnets
  → No application pods run here — only ALB support

db_nodes (database subnets, DISABLED):
  → Reserved for future database workloads in the cluster
  → Not needed now since Aurora is AWS-managed
```

**Node Name Tags — why added:**  
Without a launch template, EC2 instances show as `ip-10-1-11-129.ec2.internal` in the AWS console — no meaningful name. With the launch template, they show as `pip-project-ecommerce-worker-node` — easy to identify.

**IMDSv2 required — why:**  
`http_put_response_hop_limit = 2` is set in the launch template. Without this, containers inside pods cannot access the EC2 metadata service (IMDS), which is needed by the LB controller to auto-detect VPC ID. Setting limit to 2 allows one hop from the container through the pod network to the EC2 metadata endpoint.

---

### Security Groups — The Firewall Rules

Think of security groups as locked doors. Every resource has one. You define exactly who can knock and enter.

#### EKS Security Group (`pip-project-ecommerce-eks-sg`)

```
INBOUND:
  Port 443 — from VPC CIDR (10.1.0.0/16)
    WHY: Kubectl commands from bastion/Jenkins need HTTPS to EKS API
  All traffic — from self (same SG)
    WHY: Pod-to-pod traffic and node-to-control-plane communication

OUTBOUND:
  All traffic — to 0.0.0.0/0
    WHY: Nodes need to pull images from ECR, call AWS APIs, etc.
```

#### Aurora Security Group (`pip-project-ecommerce-aurora-sg`)

```
INBOUND:
  Port 5432 (PostgreSQL) — from EKS security group ONLY
    WHY: Only EKS pods should query the database
  Port 5432 — from Bastion security group
    WHY: Admins on bastion can query DB for debugging

OUTBOUND:
  All traffic — to 0.0.0.0/0
    WHY: Aurora needs to reach AWS APIs (CloudWatch, S3 for snapshots)
```

**Why NO port 5432 from the internet?**  
The database is in the database subnet. The database subnet has no internet gateway route. Even if you tried to connect from the internet, the VPC routing table would reject it before it even reached the SG.

#### Bastion Security Group (`pip-project-ecommerce-bastion-sg`)

```
INBOUND:
  Port 22 (SSH) — from 0.0.0.0/0
    WHY: SSH access for admins (controlled via key pair)
    BETTER: Use SSM Session Manager instead (no port 22 needed)

OUTBOUND:
  All traffic — to 0.0.0.0/0
```

#### Jenkins Security Group (`pip-project-ecommerce-jenkins-sg`)

```
INBOUND:
  Port 8080 — from Bastion SG only
    WHY: Jenkins UI only accessible via bastion (not internet)
  Port 443 — from VPC CIDR
    WHY: Internal HTTPS calls

OUTBOUND:
  All traffic — to 0.0.0.0/0
    WHY: Jenkins needs to pull from GitHub, push to ECR, call EKS API
```

---

### RDS Proxy — The Connection Pool Manager

**What problem does it solve?**  
Aurora PostgreSQL can handle approximately 700 simultaneous connections.

Without RDS Proxy:
```
14 pods × 10 connections each = 140 connections
(manageable but grows fast)

If we scale to 100 pods × 10 connections = 1000 connections
→ Aurora crashes: "too many connections"
```

With RDS Proxy:
```
100 pods → RDS Proxy → only 5 real Aurora connections
RDS Proxy handles all the multiplexing
Aurora stays healthy regardless of how many pods exist
```

**Other benefits:**
- **Automatic failover**: If the Aurora writer crashes and promotes a reader, RDS Proxy reconnects transparently. Pods don't notice.
- **TLS required**: All connections through the proxy must use TLS (`require_tls = true`). No unencrypted database traffic.
- **Secrets Manager auth**: The proxy authenticates using the DB credentials secret — not hardcoded passwords.

**Connection flow:**

```
Pod (private subnet)
  → DATABASE_URL = proxy-endpoint:5432/user_db
  → RDS Proxy (database subnet, TLS)
    → Aurora Writer Instance (database subnet)
```

---

### Aurora PostgreSQL — The Database

**What problem does it solve?**  
Stores all permanent data: users, products, cart items, orders, payments.

**Why Aurora and not regular RDS PostgreSQL?**

| Feature | Aurora | Regular RDS |
|---------|--------|------------|
| Automatic failover | < 30 seconds | 1-2 minutes |
| Read scaling | Add readers instantly | Manual |
| Global Database | ✅ Built-in cross-region | ❌ Complex setup |
| Performance | 3x faster than standard | Baseline |

**Configuration:**
- Writer: 1 instance (handles all writes)
- Readers: 2 instances across different AZs (handle read traffic, automatic failover candidates)
- Global Database: 1 replica in us-west-2 (DR region)
- Backup retention: 35 days
- CloudWatch logs: PostgreSQL query logs exported
- KMS encryption at rest
- `deletion_protection = true` in production (cannot accidentally delete)

**How pods know which database to use:**  
Each service has its own database (`user_db`, `product_db`, etc.) on the same Aurora cluster. The `DATABASE_URL` environment variable tells each pod which database to connect to:

```
user-service    → DATABASE_URL = postgresql://pipadmin:xxx@proxy:5432/user_db
product-service → DATABASE_URL = postgresql://pipadmin:xxx@proxy:5432/product_db
cart-service    → DATABASE_URL = postgresql://pipadmin:xxx@proxy:5432/cart_db
```

---

### ElastiCache Redis — The Fast Memory Store

**What problem does it solve?**  
Some data is read constantly but changes rarely. Fetching it from Aurora every time wastes time and database connections.

**Four specific uses in this project:**

**1. Cart caching (cart-service):**
```
User visits any page → frontend shows cart count
Without Redis: every page = Aurora query
With Redis: every page = Redis read (100x faster)
Cart is stored in Redis with 24-hour TTL
Written to Aurora only on checkout
```

**2. JWT session blacklist (user-service):**
```
User logs out → JWT token is "revoked"
Problem: JWT is stateless — once issued, it's valid until expiry
Solution: Store logged-out tokens in Redis with TTL = token expiry
When a request comes in: check Redis blacklist first
```

**3. Rate limiting (all services):**
```
Each service has a rate limiter
Counters: "how many requests from this IP in the last minute?"
Must work across all pod replicas consistently
Redis atomic INCR works across all pods
In-memory counters (inside each pod) would give wrong counts
```

**4. Payment idempotency keys (payment-service):**
```
User double-clicks "Pay" → two payment requests sent
Without idempotency: user gets charged twice
With Redis: first request stores key "payment:user123:txn456"
Second identical request: key already exists → reject duplicate
TTL: 5 minutes
```

---

### Secrets Manager — The Password Vault

**What problem does it solve?**  
Where do you store database passwords? If you put them in code → anyone who reads your code has the password. If you put them in environment variables in the Docker image → they appear in `docker inspect` output. If you put them in Kubernetes YAML files → they're in git history forever.

**Secrets Manager is a dedicated password vault:**
- Passwords are stored encrypted with KMS
- Access is controlled by IAM — only the specific pod role can read the specific secret
- Passwords can be rotated automatically (weekly) without changing any code
- All access is logged in CloudTrail

**Two secrets in this project:**
1. `pip-project-ecommerce-db-credentials` — Aurora username, password, host, port
2. `pip-project-ecommerce/prod/redis/auth-token` — Redis AUTH password

**How pods read secrets — the flow:**

```
Pod starts
  │
  ▼
Secrets Store CSI Driver runs (system pod in kube-system)
  │  Uses IRSA role (pod's identity) to call Secrets Manager
  ▼
Secrets Manager returns: { username, password, host }
  │
  ▼
CSI driver mounts values as files at /mnt/secrets/
  AND syncs them into a native Kubernetes Secret
  │
  ▼
Pod reads DATABASE_URL using the secretKeyRef
  │
  ▼
Prisma connects to Aurora via RDS Proxy using those credentials
```

**The password NEVER appears in:**
- Pod environment variables (visible in `kubectl describe pod`)
- Docker image
- Git repository
- Kubernetes YAML files

---

### SSM Parameter Store — The Config Store

**What problem does it solve?**  
Not everything is a secret. Some values are just configuration:
- Redis hostname
- SNS topic ARN
- SES sender email
- Internal ALB DNS name

These don't need the full security of Secrets Manager. SSM Parameter Store is simpler and cheaper for non-sensitive config.

**Two types used:**
- `String` — plain text, readable by anyone with IAM access: Redis host, SNS ARN, SES email
- `SecureString` — KMS-encrypted: JWT signing secret, internal service key

**Example parameters:**
```
/pip-project-ecommerce/prod/redis/primary-endpoint → redis.xxxx.cache.amazonaws.com
/pip-project-ecommerce/prod/sns/topic-arn          → arn:aws:sns:us-east-1:497...
/pip-project-ecommerce/prod/app/jwt-secret         → (SecureString, encrypted)
```

---

### ECR (Elastic Container Registry) — The Docker Image Store

**What problem does it solve?**  
Your 7 Docker images need to be stored somewhere so EKS can pull them when starting pods. You can't store them on DockerHub (public, insecure for private apps). ECR is AWS's private Docker registry.

**Why ECR specifically:**
- Private — only your AWS account can access it (+ accounts you grant)
- Scan-on-push — every time you push an image, ECR automatically scans it for known vulnerabilities
- Immutable tags (optional) — once you push `v1.2.0`, that tag cannot be overwritten
- Lifecycle policy — automatically delete old images (keep last 4 tagged, delete untagged after 1 day)
- Integrated with EKS — pods pull images using the node's IAM role, no credentials needed

**Repository naming:**
```
497149484677.dkr.ecr.us-east-1.amazonaws.com/pip-project-ecommerce/user-service:latest
                                             │─── repo name ──────│─service name─│─tag─│
```

---

### S3 — The Object Store

**What problem does it solve?**  
Three specific problems:

**1. ALB Access Logs:**  
Every HTTP request that hits your ALBs is logged. AWS requires these logs to go to S3 (not CloudWatch). Logs tell you:
- Which IPs visited
- What URLs were requested
- Response times
- HTTP status codes

**2. WAF Logs:**  
Every request that WAF inspects is logged. This tells you:
- Which attacks were blocked
- Which IPs are attacking you
- Which WAF rules are triggering

**3. CI/CD Artifacts:**  
Trivy scan reports, SBOM files, build metadata from the Jenkins CI pipeline are stored here for audit compliance.

**Bucket configuration:**
- Public access: BLOCKED (no one on the internet can read your logs)
- Versioning: ENABLED (can recover accidentally deleted files)
- KMS encryption: AES-256
- Lifecycle: logs → Glacier after 90 days → deleted after 365 days (saves cost)

---

### CloudWatch — The Monitoring System

**What problem does it solve?**  
How do you know your system is healthy? How do you know before users start complaining?

CloudWatch is AWS's monitoring service. It:
1. **Collects metrics** — CPU, memory, database connections, error rates, response times
2. **Fires alarms** — when a metric crosses a threshold, sends a notification
3. **Stores logs** — application logs from pods (via Fluent Bit), VPC flow logs

**22 alarms configured:**
- Aurora CPU > 80% → SNS alert
- Aurora connections > 500 → SNS alert
- Redis memory > 80% → SNS alert
- ALB 5xx errors > 10/min → SNS alert
- ALB response time p99 > 200ms → SNS alert (SLO breach)
- EKS pod restarts > 5 → SNS alert
- GuardDuty HIGH finding → PagerDuty

**Log groups:**
- `/aws/eks/pip-project-ecommerce-prod/application` — all pod logs
- `/aws/vpc/flowlogs/pip-project-ecommerce-prod` — all network traffic

---

### SNS (Simple Notification Service) — The Event Bus

**What problem does it solve?**  
Services need to communicate events without being tightly coupled.

Example without SNS:
```
payment-service → directly calls notification-service
Problem: if notification-service is down, payment fails too
Problem: payment-service needs to know notification-service's URL
Problem: if you add a new service that needs payment events, you change payment-service code
```

Example with SNS:
```
payment-service → publishes "PAYMENT_SUCCESS" to SNS topic
SNS → delivers to ALL subscribers simultaneously:
  → notification-service (sends SMS/email)
  → order-service (creates order record)
  → analytics-service (future: records purchase event)
```

Payment-service doesn't know or care who subscribes. Loose coupling.

**Also used for:**
- CloudWatch alarms → SNS → Slack notifications
- GuardDuty findings → SNS → security alerts

---

### SQS (Simple Queue Service) — The Buffer

**What problem does it solve?**  
What if SNS sends an event but the subscriber (notification-service) is temporarily down? The event is lost.

SQS stores messages in a queue. The subscriber reads from the queue when it's ready. Even if notification-service restarts, the message waits in the queue.

**In this project:** SQS is used as a Dead Letter Queue for failed Jenkins pipeline notifications. If the notification fails 3 times, it goes to the DLQ for manual investigation.

---

### KMS (Key Management Service) — The Encryption Master

**What problem does it solve?**  
Every piece of sensitive data needs to be encrypted. But who manages the encryption keys?

KMS is AWS's key management service. One KMS key is used to encrypt everything:
- Aurora database (data at rest)
- ElastiCache Redis (data at rest)
- S3 buckets (logs, artifacts)
- Secrets Manager secrets
- SSM SecureString parameters
- CloudWatch log groups

**Why one key for everything?**  
Simpler rotation, simpler auditing, simpler access control. When the key is rotated (every year automatically), all encrypted data is re-encrypted.

**Key policy — who can use the key:**
- Root account: full control (emergency access)
- CloudWatch Logs service: encrypt/decrypt log groups
- Secrets Manager service: encrypt/decrypt secrets
- EKS pods via IRSA: decrypt secrets they're authorized to read

---

## Part 4 — How Pods Connect to RDS: Step by Step

This is the most important connection to understand.

```
Step 1: Terraform creates KMS key + Secrets Manager secret
        Secret contains: username=pipadmin, password=PipEcom2026#Prod, host=proxy-endpoint

Step 2: Terraform creates IRSA role with policy:
        "allow GetSecretValue on pip-project-ecommerce-* AND pip-project-ecommerce/*"

Step 3: Terraform creates Kubernetes ServiceAccount
        annotated with: eks.amazonaws.com/role-arn = <IRSA role ARN>

Step 4: Pod starts with serviceAccountName: ecommerce-services-sa

Step 5: EKS automatically mounts a projected token into the pod
        This token proves: "I am the ecommerce-services-sa ServiceAccount"

Step 6: Secrets Store CSI Driver (system pod) reads the SecretProviderClass:
        "fetch secret pip-project-ecommerce-db-credentials from Secrets Manager"
        Uses the pod's projected token + IRSA to authenticate to AWS

Step 7: AWS verifies the token matches the IRSA trust policy
        Allows GetSecretValue

Step 8: CSI driver mounts secret values as files in /mnt/secrets/
        AND creates a Kubernetes Secret "user-db-url" with the values

Step 9: Pod reads DATABASE_URL from the Kubernetes Secret via secretKeyRef

Step 10: Prisma ORM connects:
         postgresql://pipadmin:PipEcom2026#Prod@proxy-endpoint:5432/user_db?sslmode=require

Step 11: Request goes to RDS Proxy (in database subnet)
         Proxy uses its own IAM role to verify credentials from Secrets Manager
         Proxy forwards connection to Aurora writer instance

Step 12: SQL query executes. Result returns through proxy to pod.
```

**Why this matters:** At no point does the password appear in a YAML file, environment variable, Docker image, or git commit. The password exists only in Secrets Manager and in memory during the database connection.

---

## Part 5 — Inter-Service Communication

### How Services Talk to Each Other

Two patterns are used depending on the relationship:

**Pattern 1 — Via Internal ALB (frontend to backend):**

```
Frontend pod
  │  HTTP POST http://<internal-alb-dns>/api/payments
  ▼
Internal ALB
  │  path /api/payments/* → payment-service:4005
  ▼
payment-service pod
```

The frontend uses the internal ALB because it doesn't know which payment-service pod to call. The ALB handles discovery and load balancing.

**Pattern 2 — Direct ClusterIP DNS (service to service):**

```
order-service pod
  │  HTTP GET http://payment-service.ecommerce.svc.cluster.local:4005/api/payments/TXN-123
  ▼
payment-service pod (any replica)
```

Order-service calls payment-service DIRECTLY using Kubernetes DNS, not via the Internal ALB. This is faster (one fewer hop) and works because both services are inside the same cluster. CoreDNS (running in kube-system) resolves `payment-service.ecommerce.svc.cluster.local` to the ClusterIP Service, which load-balances to any healthy pod.

**Which pattern to use when:**
- Frontend → any backend service: **Internal ALB** (frontend doesn't know internal K8s DNS)
- Backend service → another backend service: **ClusterIP DNS** (direct, faster, no extra hop)

### Internal Kubernetes DNS Format

```
<service-name>.<namespace>.svc.cluster.local

Examples:
  user-service.ecommerce.svc.cluster.local:4001
  payment-service.ecommerce.svc.cluster.local:4005
  notification-service.ecommerce.svc.cluster.local:4006
```

### Internal Service Key (`x-internal-key`)

Services that expose `/internal/*` endpoints (user-service for contact lookup) require this header:

```
order-service → GET /internal/users/uuid
                Header: x-internal-key: pip-ecom-internal-manoj-2026-prod-key-m7z

user-service checks:
  if header != INTERNAL_SERVICE_KEY: return 403 Forbidden
  else: return user contact details
```

This prevents random pods or external callers from accessing internal endpoints even if they somehow get inside the VPC.

---

## Part 6 — Security Layers Summary

```
Layer 1 — Network Edge
  Route53 → only resolves to your ALB, not your pods directly
  WAF → blocks OWASP attacks before they enter VPC

Layer 2 — VPC (Virtual Private Network)
  Public subnets: only ALBs and bastion
  Private subnets: pods (no public IP, outbound only via NAT)
  Database subnets: Aurora + Redis (no internet access at all)
  NACLs: stateless rules at subnet boundary
  Security Groups: stateful rules at resource level

Layer 3 — Kubernetes
  Namespace isolation: ecommerce namespace, kube-system namespace
  RBAC: ServiceAccounts with minimal permissions
  Network policies (optional, can add later)

Layer 4 — Application
  JWT tokens for user authentication
  Internal service key for service-to-service
  HTTPS everywhere (ALB terminates TLS)
  Input validation in each service

Layer 5 — Data
  KMS encryption for all data at rest
  TLS for all data in transit (RDS Proxy, Redis, S3)
  Secrets Manager for credentials (never in code)
  SSM SecureString for app secrets
  No passwords in environment variables
  No passwords in YAML files
  No passwords in git

Layer 6 — Detection
  GuardDuty: AI-based threat detection
  CloudWatch: 22 alarms
  VPC Flow Logs: all network traffic recorded
  CloudTrail: all AWS API calls logged
  WAF logs → S3
  ALB access logs → S3
```

---

## Part 7 — Why Each Service Exists (One-Line Summary)

| Service | Problem It Solves |
|---------|------------------|
| Route53 | Translates `ecommerce-pip.com` to an IP. Switches to DR region automatically if primary fails. |
| WAF | Blocks SQL injection, XSS, DDoS, bad bots before they reach your app. |
| External ALB | Distributes HTTPS traffic across frontend pods. Terminates TLS. |
| Internal ALB | Routes frontend API calls to the correct backend service by URL path. |
| EKS | Runs and manages all Docker containers. Auto-restarts crashed pods. Scales on traffic. |
| Aurora PostgreSQL | Permanent storage for users, products, cart, orders, payments. Multi-AZ, automatic failover. |
| RDS Proxy | Prevents "too many connections" error. Transparent failover. Secure auth via Secrets Manager. |
| ElastiCache Redis | Fast cache for cart data, session blacklist, rate limits, payment idempotency. |
| Secrets Manager | Stores DB password + Redis auth token. Encrypted, audited, automatically rotatable. |
| SSM Parameter Store | Stores non-secret config: Redis host, SNS ARN, internal ALB DNS, SES email. |
| ECR | Private Docker image registry. Scans images for vulnerabilities on every push. |
| S3 | Stores WAF logs, ALB access logs, CI artifacts. Required by AWS for ALB logging. |
| CloudWatch | Monitors 22 metrics. Fires alarms when thresholds are breached. |
| SNS | Event bus: payment success → notification SMS. Decouples services. |
| SQS | Buffer: stores failed messages for retry. Dead letter queue for pipeline alerts. |
| KMS | One key encrypts everything: Aurora, Redis, S3, Secrets Manager, SSM. |
| GuardDuty | AI threat detection: crypto-mining, compromised credentials, unusual API calls. |
| ACM | Free SSL/TLS certificates. Auto-renews. No manual cert management. |

---

*Document version: 1.0 | Project: pip-project-ecommerce*  
*Read alongside: architecture.md (draw.io diagram) and how-it-works.md (user journey walkthrough)*
