# Runbook: Incident Response

**Project:** pip-project-ecommerce  
**Purpose:** Step-by-step guide for responding to production incidents  
**Audience:** On-call engineer, DevOps team  
**Last updated:** 2026

---

## What is an Incident?

An **incident** is any unplanned event that causes the application to be unavailable, slow, or incorrect for users.

### Severity Levels

| Level | Name | Definition | Response Time | Example |
|-------|------|-----------|--------------|---------|
| **P1** | Critical | Complete outage. All users affected. | **Immediate (< 5 min)** | Website returns 503 for all users |
| **P2** | High | Major feature broken. Many users affected. | **< 30 minutes** | Payments failing for all users |
| **P3** | Medium | Minor feature broken. Some users affected. | **< 4 hours** | Notifications not sending |
| **P4** | Low | Cosmetic issue. Few users affected. | **Next business day** | Wrong text on a page |

---

## Incident Response Process

```
Alert fires (CloudWatch → SNS → Slack / PagerDuty)
        │
        ▼
Step 1: DETECT    — Someone sees the alert or a user reports it
        │
        ▼
Step 2: TRIAGE    — How bad is it? What is the P-level?
        │
        ▼
Step 3: CONTAIN   — Stop the bleeding. Prevent more users being affected.
        │
        ▼
Step 4: DIAGNOSE  — Find the root cause.
        │
        ▼
Step 5: RESOLVE   — Fix it.
        │
        ▼
Step 6: RECOVER   — Verify everything is back to normal.
        │
        ▼
Step 7: DOCUMENT  — Write a post-mortem within 24 hours.
```

---

## Scenario 1: Website is Down (P1)

**Symptoms:** Users report the website is not loading. ALB health check alarm fires.

### Step 1 — Verify the problem (2 minutes)

```bash
# Check if the website responds
curl -I https://ecommerce-pip.com

# Expected: HTTP/2 200
# Problem: Connection refused / 502 / 503
```

### Step 2 — Check ALB health (3 minutes)

```bash
# Get your AWS credentials set up
aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region us-east-1

# Check pod status
kubectl get pods -n ecommerce

# If pods are not running, check events
kubectl describe pod <pod-name> -n ecommerce
kubectl logs <pod-name> -n ecommerce --tail=50
```

### Step 3 — Check each service health endpoint

```bash
# Port-forward to check directly (bypasses ALB)
kubectl port-forward svc/frontend-service 3000:80 -n ecommerce &
curl http://localhost:3000/

# Check each service
for port in 4001 4002 4003 4004 4005 4006; do
  kubectl port-forward svc/$(kubectl get svc -n ecommerce -o name | grep $port) $port:$port -n ecommerce &
  sleep 2
  curl -s http://localhost:$port/health | jq .status
done
```

### Step 4 — Decision tree

```
Are pods running?
│
├── NO → Go to "Pod Crash" scenario below
│
└── YES
    │
    Are pods passing health checks?
    │
    ├── NO → Check logs: kubectl logs <pod> -n ecommerce
    │        Common: DB connection failed, secret not mounted
    │
    └── YES
        │
        Is the ALB forwarding traffic?
        │
        ├── Check ALB target group health in AWS console
        └── If targets unhealthy: check security group allows ALB to reach pods
```

---

## Scenario 2: Database Connection Failures (P2)

**Symptoms:** Services return 500 errors. Logs show "Connection refused" or "too many connections".

### Step 1 — Check RDS Proxy status

```bash
# Check from AWS CLI
aws rds describe-db-proxies \
  --db-proxy-name pip-project-ecommerce-proxy \
  --region us-east-1 \
  --query 'DBProxies[0].Status'

# Expected: available
# Problem: modifying / unavailable
```

### Step 2 — Check Aurora cluster status

```bash
aws rds describe-db-clusters \
  --db-cluster-identifier pip-project-ecommerce-cluster \
  --region us-east-1 \
  --query 'DBClusters[0].Status'

# Expected: available
```

### Step 3 — Check connection count alarm

```
AWS Console → CloudWatch → Alarms
Look for: pip-project-ecommerce-aurora-connections-high
If ALARM state: connections are above 500
```

### Step 4 — Fix: Too many connections

```bash
# Scale down pods temporarily to reduce connections
kubectl scale deployment user-service-deployment --replicas=1 -n ecommerce
kubectl scale deployment product-service-deployment --replicas=1 -n ecommerce
kubectl scale deployment cart-service-deployment --replicas=1 -n ecommerce

# Wait 2 minutes for connections to drain, then check
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBClusterIdentifier,Value=pip-project-ecommerce-cluster \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Average \
  --region us-east-1

# Once connection count drops, scale back up
kubectl scale deployment user-service-deployment --replicas=2 -n ecommerce
```

---

## Scenario 3: High Memory / CPU on EKS Nodes (P2)

**Symptoms:** CloudWatch alarm fires for node CPU > 80%. Pods are pending.

### Step 1 — Check node resource usage

```bash
# Check node capacity
kubectl top nodes

# Check which pods are using most resources
kubectl top pods -n ecommerce --sort-by=memory

# Check for pending pods
kubectl get pods -n ecommerce | grep Pending
```

### Step 2 — Check Cluster Autoscaler logs

```bash
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=cluster-autoscaler \
  --tail=30
```

### Step 3 — If autoscaler is not scaling

```bash
# Check autoscaler is running
kubectl get pods -n kube-system | grep autoscaler

# Check node group limits in AWS
aws autoscaling describe-auto-scaling-groups \
  --region us-east-1 \
  --query 'AutoScalingGroups[?contains(Tags[?Key==`eks:cluster-name`].Value, `pip-project-ecommerce`)].[AutoScalingGroupName,MinSize,MaxSize,DesiredCapacity]' \
  --output table
```

### Step 4 — Emergency: Manually scale node group

```bash
# If autoscaler is stuck, manually increase desired capacity
aws eks update-nodegroup-config \
  --cluster-name pip-project-ecommerce-cluster \
  --nodegroup-name pip-project-ecommerce-workers \
  --scaling-config minSize=3,maxSize=10,desiredSize=5 \
  --region us-east-1
```

---

## Scenario 4: Failover to DR Region (P1 — Region Failure)

**Symptoms:** us-east-1 is having issues. Route53 health check alarm fires.

### Step 1 — Confirm regional failure (5 minutes)

```
Check: https://health.aws.amazon.com/health/status
Check: AWS Service Health Dashboard for us-east-1
If confirmed regional issue → proceed to failover
```

### Step 2 — Promote Aurora Global Database (2 minutes)

```bash
# Remove secondary cluster from global DB and promote it to standalone
aws rds remove-from-global-cluster \
  --global-cluster-identifier pip-project-ecommerce-global-db \
  --db-cluster-identifier pip-project-ecommerce-cluster-dr \
  --region us-west-2

# Wait for promotion to complete
aws rds wait db-cluster-available \
  --db-cluster-identifier pip-project-ecommerce-cluster-dr \
  --region us-west-2

echo "Aurora DR cluster is now the writer"
```

### Step 3 — Update Route53 (automatic via health checks)

```
Route53 health check detects primary ALB unhealthy
→ Automatically switches DNS to DR ALB
→ DNS propagation: ~60 seconds (TTL is 60s)

Verify:
nslookup ecommerce-pip.com
# Should return DR region ALB IP
```

### Step 4 — Spin up EKS in DR region (us-west-2)

```bash
# Run infra pipeline for prod with DR region active
# OR manually:
cd 01-Infrastructure/environments/prod
terraform apply -var-file=prod.tfvars \
  -var "primary_region=us-west-2"
```

### Step 5 — Verify DR is serving traffic

```bash
curl -I https://ecommerce-pip.com
# Should return 200

curl https://ecommerce-pip.com/api/users/health
# Should return {"status":"ok"}
```

---

## Scenario 5: GuardDuty HIGH Finding (P2)

**Symptoms:** CloudWatch alarm `pip-project-ecommerce-guardduty-high-findings` fires.

### Step 1 — Review the finding

```
AWS Console → GuardDuty → Findings
Filter: Severity = HIGH or CRITICAL
Click the finding to see details
```

### Step 2 — Common findings and actions

| Finding Type | What It Means | Immediate Action |
|-------------|---------------|-----------------|
| `UnauthorizedAccess:EC2/SSHBruteForce` | Someone is trying SSH brute-force on EC2 | Check bastion SG — should be SSM-only, no port 22 open |
| `CryptoCurrency:EC2/BitcoinTool.B` | EC2 instance mining crypto | Immediately stop the instance, investigate |
| `Backdoor:EC2/C&CActivity.B` | EC2 communicating with known bad IP | Isolate instance, rotate all credentials |
| `UnauthorizedAccess:IAMUser/TorIPCaller` | AWS API calls from Tor network | Rotate access keys immediately |
| `Persistence:Kubernetes/AnomalousBehavior` | Unusual K8s API calls | Review kubectl audit logs, check for rogue pods |

### Step 3 — Isolate a compromised resource

```bash
# If an EKS pod is compromised
kubectl cordon <node-name>           # Stop new pods scheduling here
kubectl drain <node-name> --force    # Move existing pods elsewhere
# Then terminate the EC2 instance from AWS console

# If an IAM user key is compromised
aws iam delete-access-key \
  --access-key-id <KEY_ID> \
  --user-name <USER_NAME>
```

---

## Post-Incident Checklist

After every P1 or P2 incident, complete this within 24 hours:

```
□ Incident duration recorded (start time → end time)
□ Root cause identified (1-2 sentences)
□ Timeline written (what happened minute by minute)
□ Contributing factors listed
□ Action items created (with owner + due date)
□ Runbook updated if this scenario was new
□ Slack #incidents channel updated with summary
□ Monitoring improved to detect this faster next time
```

### Post-Mortem Template

```markdown
## Incident: [SHORT TITLE] — [DATE]

**Duration:** [START TIME] to [END TIME] ([X minutes])
**Severity:** P[1/2/3]
**Impact:** [X users affected, X% of traffic impacted]

### What Happened
[2-3 sentences describing what the user experienced]

### Root Cause
[The actual technical reason the incident occurred]

### Timeline
- HH:MM — Alert fired
- HH:MM — On-call engineer acknowledged
- HH:MM — Root cause identified
- HH:MM — Fix deployed
- HH:MM — Service restored

### Contributing Factors
- [e.g. No load test was done before deploy]
- [e.g. Alarm threshold was too high to catch early]

### Action Items
| Action | Owner | Due Date |
|--------|-------|----------|
| [e.g. Add health check for DB connection at startup] | [name] | [date] |
```

---

*Document version: 1.0 | Project: pip-project-ecommerce*
