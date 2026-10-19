# Disaster Recovery Runbook

**Project:** pip-project-ecommerce  
**Primary Region:** us-east-1 (N. Virginia)  
**DR Region:** us-west-2 (Oregon)  
**Target RTO:** < 2 minutes (traffic rerouted)  
**Target RPO:** < 1 hour (data loss window)  
**Last Updated:** 2026

---

## Before You Start — Read This First

This document tells you exactly what to do, step by step, if the primary AWS region (us-east-1) fails.

**Think of it like this:**
- Your production app runs in us-east-1 (your main office)
- us-west-2 has a warm standby (your backup office)
- When the main office has a fire, you move operations to the backup office
- This document is the fire drill — follow it exactly, do not skip steps

**Who runs this:** The on-call engineer. You can do this alone — no extra help needed.

**Tools you need on your laptop before starting:**
- AWS CLI configured (`aws configure`)
- kubectl installed
- terraform installed
- git access to this repo

**Time estimate per phase:**
```
Phase 1 — Confirm failure:     5 minutes
Phase 2 — Reroute traffic:     2 minutes (mostly automatic)
Phase 3 — Promote database:    3 minutes
Phase 4 — Spin up DR cluster:  25-35 minutes
Phase 5 — Deploy application:  10 minutes
Phase 6 — Verify everything:   10 minutes
Phase 7 — Notify stakeholders: 5 minutes
─────────────────────────────────────────
Total:                        ~60 minutes to full recovery
Traffic rerouted at:          ~2 minutes (users back online fast)
```

---

## Current Architecture — Normal Operation

```
User's Browser
      │ HTTPS
      ▼
Route53 (DNS) → ecommerce-pip.com
      │ resolves to ↓
      ▼
AWS WAF  (blocks attacks)
      │
      ▼
External ALB  [us-east-1, public subnets]
      │
      ▼
EKS Pods  [us-east-1, private subnets]
  frontend + 6 backend services
      │
      ▼
RDS Proxy → Aurora PostgreSQL  [us-east-1, database subnets]
  pip-project-ecommerce-cluster (writer + 2 readers)
      │ replicates continuously
      ▼
Aurora Global DB  [us-west-2, STANDBY — read-only]
  pip-project-ecommerce-cluster-dr
```

**What is ready in us-west-2 RIGHT NOW:**
- ✅ Aurora secondary cluster running (read-only replica, lag < 1 second)
- ❌ EKS cluster — NOT running (to save cost, spun up only during DR)
- ❌ WAF — NOT configured (configured during DR)
- ✅ Route53 health check configured — will auto-detect failure

---

## PHASE 1 — Confirm the Failure (5 minutes)

Do not skip this. Many "outages" are monitoring glitches, not real failures.

### Step 1.1 — Check the AWS Service Health Dashboard

Open this URL in your browser:
```
https://health.aws.amazon.com/health/status
```

Look for: **us-east-1** listed as degraded or unavailable.

Also check the AWS status page:
```
https://status.aws.amazon.com/
```

If neither shows an issue → **the problem may be in your application, not AWS**. Go to the incident-response runbook instead.

### Step 1.2 — Try to reach your application yourself

```bash
# Try the website
curl -I https://ecommerce-pip.com

# Try the health endpoints directly (bypasses DNS caching)
curl -I https://ecommerce-pip.com/api/users/health

# Check what DNS is returning
nslookup ecommerce-pip.com
```

**If the website is unreachable AND AWS confirms us-east-1 is down → proceed to Phase 2.**

### Step 1.3 — Check Route53 health check status

```bash
# List all health checks
aws route53 list-health-checks \
  --query 'HealthChecks[*].[Id,HealthCheckConfig.FullyQualifiedDomainName,HealthCheckConfig.Type]' \
  --output table

# Get the health check status
aws route53 get-health-check-status \
  --health-check-id <HEALTH_CHECK_ID>
```

If Route53 already shows the health check as UNHEALTHY → DNS failover may already be happening automatically. Check Step 2.1 before doing anything manually.

---

## PHASE 2 — Reroute Traffic to DR (2 minutes, mostly automatic)

### How automatic failover works

We set up Route53 with a **failover routing policy**:

```
Route53 record for ecommerce-pip.com:
  PRIMARY:  → us-east-1 ALB  (health check every 10 seconds)
  SECONDARY: → us-west-2 ALB  (used when primary is unhealthy)
```

When the health check fails 3 consecutive times (30 seconds), Route53 automatically updates DNS to point to the DR ALB.

### Step 2.1 — Check if automatic failover already happened

```bash
# Check current DNS resolution
nslookup ecommerce-pip.com

# Compare with us-east-1 ALB hostname (from AWS console)
# If DNS now returns a us-west-2 address → failover already happened
# us-east-1 ALB IPs are different from us-west-2 ALB IPs
```

### Step 2.2 — If automatic failover has NOT happened yet

The DR ALB in us-west-2 may not exist yet (we create it during DR). So we need to:
1. Create the EKS cluster in us-west-2 first (Phase 4)
2. Then the ALB will be provisioned
3. Then manually update Route53 if the health check hasn't done it automatically

**Note:** While you work through Phases 3 and 4, Route53 health check will likely trigger automatic failover. Traffic will go to us-west-2 the moment a healthy ALB exists there and DNS propagates (TTL: 60 seconds).

---

## PHASE 3 — Promote Aurora Database (3 minutes)

> **This is the most critical step.** The database is the source of truth for all orders, users, products, and payments. We must promote the DR replica to a writer BEFORE the EKS cluster connects to it.

### Why promotion is needed

The Aurora DR cluster in us-west-2 is currently **read-only**. It receives every write from us-east-1 via replication. When we promote it, it becomes a standalone writer that accepts reads AND writes.

```
Before promotion:
  us-east-1 Aurora Writer ──replicates──► us-west-2 Aurora (read-only)

After promotion:
  us-east-1 Aurora Writer ──DISCONNECTED
  us-west-2 Aurora ──promoted to Writer─► accepts reads + writes
```

### Step 3.1 — Check current replication lag

```bash
# Check how far behind the DR cluster is
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name AuroraGlobalDBReplicationLag \
  --dimensions Name=DBClusterIdentifier,Value=pip-project-ecommerce-cluster-dr \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Average \
  --region us-west-2

# Result is in milliseconds
# If < 1000ms (1 second) → safe to promote, minimal data loss
# If > 60000ms (1 minute) → some data loss expected, document it
```

Write down the replication lag here: **_______ ms** (this is your RPO for this incident)

### Step 3.2 — Remove DR cluster from Global Database and promote

```bash
# This single command breaks the replication link and promotes
# the DR cluster to a standalone writer cluster
aws rds remove-from-global-cluster \
  --global-cluster-identifier pip-project-ecommerce-global-db \
  --db-cluster-identifier pip-project-ecommerce-cluster-dr \
  --region us-west-2
```

Expected output:
```json
{
    "GlobalCluster": {
        "GlobalClusterIdentifier": "pip-project-ecommerce-global-db",
        "Status": "available"
    }
}
```

### Step 3.3 — Wait for promotion to complete

```bash
# Watch the cluster status change from "promoting" to "available"
# Run this command every 10 seconds until you see "available"
watch -n 10 "aws rds describe-db-clusters \
  --db-cluster-identifier pip-project-ecommerce-cluster-dr \
  --region us-west-2 \
  --query 'DBClusters[0].Status' \
  --output text"

# Typical promotion time: 1-2 minutes
```

When you see `available` → the database is promoted and ready.

### Step 3.4 — Get the new writer endpoint

```bash
# Get the writer endpoint for the promoted DR cluster
aws rds describe-db-clusters \
  --db-cluster-identifier pip-project-ecommerce-cluster-dr \
  --region us-west-2 \
  --query 'DBClusters[0].Endpoint' \
  --output text
```

Write this down: **DB writer endpoint: _______________________________**

You will need this in Phase 5 to update the database connection for the application.

### Step 3.5 — Update Secrets Manager with new DB endpoint

The pods read the DB host from Secrets Manager. Update it so new pods connect to the DR database:

```bash
# Get the current secret value
aws secretsmanager get-secret-value \
  --secret-id pip-project-ecommerce-db-credentials \
  --region us-west-2 \
  --query SecretString \
  --output text

# Update the host to point to the promoted DR cluster endpoint
DR_DB_HOST="<paste the endpoint from Step 3.4>"

aws secretsmanager put-secret-value \
  --secret-id pip-project-ecommerce-db-credentials \
  --region us-west-2 \
  --secret-string "{
    \"username\": \"pipadmin\",
    \"password\": \"<your_db_password>\",
    \"engine\": \"postgres\",
    \"port\": 5432,
    \"host\": \"${DR_DB_HOST}\"
  }"

echo "✅ Secrets Manager updated with DR database endpoint"
```

---

## PHASE 4 — Provision EKS Cluster in DR Region (25-35 minutes)

The EKS cluster in us-west-2 does not exist yet. We provision it now using Terraform.

> ☕ **This phase takes 25-35 minutes.** While Terraform runs, the database is already promoted and Route53 is rerouting traffic. Users may see errors until Phase 5 completes — that is expected.

### Step 4.1 — Set environment variables

```bash
export AWS_DEFAULT_REGION=us-west-2

export TF_VAR_db_master_password="<your Aurora master password>"
export TF_VAR_jwt_secret="<your JWT secret>"
export TF_VAR_internal_service_key="<your internal service key>"
export TF_VAR_redis_auth_token="<your Redis auth token>"
```

> **Where to find these values:** They are stored in AWS Secrets Manager in us-east-1. If us-east-1 is completely unavailable, use the values you recorded when you first ran the infra pipeline. Keep these in a secure password manager — not in git.

### Step 4.2 — Update prod.tfvars for DR region

```bash
cd 01-Infrastructure/environments/prod
```

Edit `prod.tfvars` — change the primary region to us-west-2:

```hcl
# Temporary DR configuration — revert after primary region recovers
primary_region = "us-west-2"   # was us-east-1
dr_region      = "us-east-1"   # swap the regions
environment    = "prod"

# us-west-2 availability zones
azs = ["us-west-2a", "us-west-2b", "us-west-2c"]

# us-west-2 specific values
ami_id = "ami-0ecc74eca1d66d8a6"   # Amazon Linux 2023, us-west-2

# Keep everything else the same
```

> **Do NOT commit this change to git yet.** Make the change locally, apply, then revert after recovery.

### Step 4.3 — Run Terraform plan to confirm what will be created

```bash
terraform init -reconfigure
terraform plan \
  -var-file=prod.tfvars \
  -var "domain_name=ecommerce-pip.com" \
  -out=dr-tfplan.binary

# Review the plan — you should see VPC, EKS, ElastiCache being created
# Aurora should NOT be created (it already exists as pip-project-ecommerce-cluster-dr)
terraform show -no-color dr-tfplan.binary | head -50
```

### Step 4.4 — Apply (this takes ~25-35 minutes)

```bash
terraform apply dr-tfplan.binary
```

While this runs, you will see resources being created in order:
```
1. VPC + subnets + route tables + security groups   (~3 min)
2. KMS keys + Secrets Manager + SSM params          (~1 min)
3. IAM roles                                        (~1 min)
4. EKS cluster (control plane)                      (~15 min)  ← longest step
5. EKS node groups                                  (~5 min)
6. Helm addons (LB controller, autoscaler, etc.)    (~5 min)
7. ElastiCache Redis                                (~5 min)
8. WAF + S3 logs bucket                             (~1 min)
```

### Step 4.5 — Update kubeconfig to point to DR cluster

```bash
aws eks update-kubeconfig \
  --name pip-project-ecommerce-cluster \
  --region us-west-2

# Verify connection
kubectl cluster-info
kubectl get nodes

# You should see 3 nodes in Ready state
```

---

## PHASE 5 — Deploy Application to DR Cluster (10 minutes)

The EKS cluster is running but empty. Deploy everything.

### Step 5.1 — Apply K8s namespace and secrets first

```bash
cd <repo-root>

# Create the namespace
kubectl apply -f 03-Kubernetes/namespace.yaml

# Apply SecretProviderClass — tells CSI driver where to get secrets from Secrets Manager
kubectl apply -f 03-Kubernetes/secrets/

# Verify secrets are readable
kubectl get secretproviderclass -n ecommerce
```

### Step 5.2 — Apply the shared ConfigMap

The ConfigMap has the Redis host, SNS ARN, and other non-sensitive config. Update it first with the DR region values:

```bash
# Get Redis endpoint from the new ElastiCache cluster
DR_REDIS_HOST=$(aws elasticache describe-replication-groups \
  --replication-group-id pip-project-ecommerce-redis \
  --region us-west-2 \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' \
  --output text)

echo "Redis host: $DR_REDIS_HOST"

# Update the ConfigMap with DR values
kubectl create configmap ecommerce-config \
  --namespace ecommerce \
  --from-literal=aws_region=us-west-2 \
  --from-literal=redis_host=$DR_REDIS_HOST \
  --from-literal=redis_port=6379 \
  --from-literal=sns_topic_arn=$(aws sns list-topics --region us-west-2 \
    --query "Topics[?contains(TopicArn,'pip-project-ecommerce')].TopicArn" \
    --output text) \
  --from-literal=ses_from_email=noreply@ecommerce-pip.com \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 5.3 — Deploy backend services

```bash
# Deploy all 6 backend services
kubectl apply -f 03-Kubernetes/services/ --recursive

# Watch pods come up
kubectl get pods -n ecommerce -w

# Wait until all pods show Running (1-2 minutes each)
# Expected: 2 replicas per service = 12 backend pods
```

### Step 5.4 — Deploy frontend

```bash
kubectl apply -f 03-Kubernetes/frontend/

# Wait for frontend pods
kubectl rollout status deployment/frontend-deployment -n ecommerce --timeout=300s
```

### Step 5.5 — Wait for ALB to be provisioned

The AWS Load Balancer Controller creates the ALB when the Ingress resource is applied. This takes 2-3 minutes.

```bash
# Watch for the ALB to get an address
kubectl get ingress -n ecommerce -w

# Wait until ADDRESS column shows a value like:
# k8s-ecommerce-frontend-xxxx.us-west-2.elb.amazonaws.com
```

Write down the DR ALB DNS: **_________________________________**

### Step 5.6 — Update Route53 to point to DR ALB

```bash
DR_ALB_DNS="<paste from Step 5.5>"
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='ecommerce-pip.com.'].Id" \
  --output text | cut -d'/' -f3)

# Update the A record to point directly to DR ALB
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"ecommerce-pip.com\",
        \"Type\": \"A\",
        \"AliasTarget\": {
          \"HostedZoneId\": \"Z1H1FL5HABSF5\",
          \"DNSName\": \"${DR_ALB_DNS}\",
          \"EvaluateTargetHealth\": true
        }
      }
    }]
  }"

echo "✅ Route53 updated to DR ALB"
echo "DNS will propagate in ~60 seconds (TTL is 60)"
```

---

## PHASE 6 — Verify Everything is Working (10 minutes)

Do every check. Do not skip any.

### Step 6.1 — Database check

```bash
# Confirm the DR Aurora cluster is the writer
aws rds describe-db-clusters \
  --db-cluster-identifier pip-project-ecommerce-cluster-dr \
  --region us-west-2 \
  --query 'DBClusters[0].{Status:Status,Writer:DBClusterMembers[0].IsClusterWriter}' \
  --output table

# Expected: Status=available, IsClusterWriter=true
```

### Step 6.2 — EKS nodes check

```bash
# All nodes should be Ready
kubectl get nodes

# Expected output (3 nodes):
# NAME                          STATUS   ROLES    AGE   VERSION
# ip-10-x-x-x.us-west-2...     Ready    <none>   5m    v1.32.x
# ip-10-x-x-x.us-west-2...     Ready    <none>   5m    v1.32.x
# ip-10-x-x-x.us-west-2...     Ready    <none>   5m    v1.32.x
```

### Step 6.3 — Pods check

```bash
# All pods should be Running
kubectl get pods -n ecommerce

# If any pod is in Error or CrashLoopBackOff:
kubectl logs <pod-name> -n ecommerce --tail=30
# Most likely cause: wrong DB host or Redis host in secrets/configmap
```

### Step 6.4 — Health endpoint checks

```bash
# Check each service health
for port in 4001 4002 4003 4004 4005 4006; do
  POD=$(kubectl get pods -n ecommerce -o name | head -1)
  echo -n "Port $port: "
  kubectl exec -n ecommerce $POD -- \
    curl -sf http://localhost:$port/health 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "FAILED"
done
```

### Step 6.5 — Full smoke test from outside

```bash
# Wait 60 seconds for DNS to propagate first
sleep 60

# Test the website responds
curl -I https://ecommerce-pip.com
# Expected: HTTP/2 200

# Test the user health endpoint
curl -s https://ecommerce-pip.com/api/users/health | python3 -m json.tool
# Expected: {"service": "user-service", "status": "ok"}

# Test product listing (read from DB)
curl -s https://ecommerce-pip.com/api/products | python3 -m json.tool
# Expected: {"products": [...]}
```

### Step 6.6 — ALB health check

```bash
# Check all target groups have healthy targets
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --region us-west-2 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text) \
  --region us-west-2 \
  --query 'TargetHealthDescriptions[*].{Target:Target.Id,Health:TargetHealth.State}' \
  --output table

# Expected: all targets showing "healthy"
```

### Step 6.7 — End-to-end user journey test

```bash
# 1. Register a test user
curl -X POST https://ecommerce-pip.com/api/users/register \
  -H "Content-Type: application/json" \
  -d '{"name":"DR Test","email":"drtest@test.com","phone":"9999999999","password":"DrTest123!"}'

# Expected: {"user":{"id":"...","name":"DR Test",...}}

# 2. Login
curl -X POST https://ecommerce-pip.com/api/users/login \
  -H "Content-Type: application/json" \
  -d '{"email":"drtest@test.com","phone":"9999999999","password":"DrTest123!"}'

# Expected: {"token":"eyJ...","user":{...}}
# Copy the token

# 3. List products (confirms DB reads work)
curl https://ecommerce-pip.com/api/products
# Expected: {"products":[...]}
```

If all three work → **DR is fully operational.** 🎉

---

## PHASE 7 — Notify Stakeholders (5 minutes)

### Step 7.1 — Post to Slack #incidents

```
🚨 INCIDENT UPDATE — DR FAILOVER COMPLETE

Time:       [current time UTC]
Status:     ✅ Service RESTORED
Affected:   [describe what users saw, e.g. "Website unavailable for X minutes"]
Root cause: us-east-1 regional issue — [brief description]
Resolution: Failed over to us-west-2 DR region
Data loss:  [X ms replication lag at time of failover]

Users can now access https://ecommerce-pip.com normally.
We are monitoring the DR environment closely.
Post-mortem will be published within 24 hours.
```

### Step 7.2 — Create incident ticket

Open a ticket in your project management tool with:
- Incident start time
- Detection time (how long before anyone noticed)
- Recovery time
- Impact (how many users, which features)
- Replication lag at failover time

---

## PHASE 8 — After Primary Region Recovers (Optional)

Once us-east-1 is healthy again, you can fail back.

> **Do not rush this.** The DR environment in us-west-2 is fully functional. Run it for at least 24 hours after primary recovery before failing back.

### Step 8.1 — Rebuild Aurora Global Database

```bash
# Create a new global cluster with us-east-1 as primary again
# The old us-east-1 cluster is destroyed — create a fresh one via Terraform
# OR add the us-west-2 cluster as new primary and us-east-1 as new DR

# Option: Use Terraform to rebuild primary region
cd 01-Infrastructure/environments/prod

# Revert prod.tfvars to original values:
# primary_region = "us-east-1"
# dr_region      = "us-west-2"

terraform apply -var-file=prod.tfvars [all TF_VAR values]
```

### Step 8.2 — Failback traffic to us-east-1

Once us-east-1 EKS + Aurora are running and healthy:

```bash
# Update Route53 to point back to us-east-1 ALB
# (same command as Step 5.6 but with us-east-1 ALB DNS and zone ID Z35SXDOTRQ7X7K)
```

### Step 8.3 — Destroy DR environment (cost saving)

```bash
cd 01-Infrastructure/environments/prod
# Set primary_region back to us-east-1 in prod.tfvars
# Then destroy the us-west-2 resources
terraform destroy -var-file=prod.tfvars \
  -target=module.eks \
  -target=module.eks_addons \
  -target=module.elasticache
```

---

## Quick Reference Card

Print this and keep it at your desk.

```
┌─────────────────────────────────────────────────────────────┐
│           DR QUICK REFERENCE — pip-project-ecommerce        │
├─────────────────────────────────────────────────────────────┤
│ PRIMARY:  us-east-1  │  DR:  us-west-2                      │
├─────────────────────────────────────────────────────────────┤
│ Aurora primary:  pip-project-ecommerce-cluster (us-east-1)  │
│ Aurora DR:       pip-project-ecommerce-cluster-dr (us-west-2)│
│ Global DB:       pip-project-ecommerce-global-db             │
│ EKS cluster:     pip-project-ecommerce-cluster               │
│ RDS Proxy:       pip-project-ecommerce-proxy                 │
├─────────────────────────────────────────────────────────────┤
│ PHASE 1: Confirm failure (5 min)                             │
│   health.aws.amazon.com → check us-east-1                   │
│                                                             │
│ PHASE 2: Traffic reroute (2 min, automatic via Route53)      │
│   Check: nslookup ecommerce-pip.com                         │
│                                                             │
│ PHASE 3: Promote Aurora (3 min)                              │
│   aws rds remove-from-global-cluster \                      │
│     --global-cluster-identifier pip-project-ecommerce-global-db \│
│     --db-cluster-identifier pip-project-ecommerce-cluster-dr \│
│     --region us-west-2                                       │
│                                                             │
│ PHASE 4: Terraform EKS in us-west-2 (30 min)                 │
│   Edit prod.tfvars: primary_region = "us-west-2"            │
│   terraform apply dr-tfplan.binary                          │
│                                                             │
│ PHASE 5: Deploy K8s app (10 min)                             │
│   kubectl apply -f 03-Kubernetes/  --recursive              │
│   Update Route53 to DR ALB                                  │
│                                                             │
│ PHASE 6: Verify (10 min)                                     │
│   curl -I https://ecommerce-pip.com → 200 OK               │
│   curl .../api/users/health → {"status":"ok"}              │
│   Register + login test user                                │
├─────────────────────────────────────────────────────────────┤
│ CONTACTS                                                     │
│   On-call lead:  ___________________________                 │
│   AWS TAM:       ___________________________                 │
│   Slack:         #incidents                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## Common Problems and Fixes

| Problem | Symptom | Fix |
|---------|---------|-----|
| Pods stuck in Pending | `kubectl get pods` shows Pending | Nodes not ready yet — wait 5 more minutes for EKS node group |
| Pods in CrashLoopBackOff | `kubectl logs <pod>` shows DB connection error | Secrets Manager not updated with new DB host — redo Step 3.5 |
| ALB health check failing | `aws elbv2 describe-target-health` shows unhealthy | Pods not ready — check pod status with `kubectl get pods -n ecommerce` |
| DNS still pointing to us-east-1 | `nslookup ecommerce-pip.com` returns old IP | Wait 60 seconds (TTL) OR manually force-update Route53 record |
| Redis connection refused | Cart/payment pods crashing | ElastiCache not ready yet — wait 5 minutes then restart pods |
| Terraform apply fails | Provider error or region mismatch | Make sure `primary_region = "us-west-2"` in prod.tfvars and run `terraform init -reconfigure` |
| Aurora promotion stuck | Status stays "promoting" for > 5 minutes | Check AWS RDS console in us-west-2 for error events |
| No DB password available | TF_VAR not set | Check AWS Secrets Manager in us-east-1 (if accessible) or use your secure notes |

---

## DR Test Schedule

Run a DR test every 6 months to make sure this runbook still works.

| Test | Frequency | What to test |
|------|-----------|-------------|
| DNS failover simulation | Every 6 months | Manually trigger Route53 health check failure |
| Aurora promotion test | Every 6 months | Promote DR cluster to writer, then revert |
| Full DR drill | Annually | Follow all phases in a separate test environment |
| Backup restore test | Quarterly | Restore Aurora snapshot to verify backup integrity |

---

*Document version: 1.0 | Project: pip-project-ecommerce*  
*Keep this document updated whenever infrastructure changes.*  
*Print the Quick Reference Card and keep it accessible offline.*
