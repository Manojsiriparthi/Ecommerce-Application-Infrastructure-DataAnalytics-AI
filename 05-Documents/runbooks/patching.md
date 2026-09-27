# Runbook: Patching Procedures

**Project:** pip-project-ecommerce  
**Purpose:** How to apply security patches and updates without downtime  
**Audience:** DevOps engineer, security team  
**Patching schedule:** Every Sunday 04:00–06:00 UTC (maintenance window)

---

## Why Patching Matters

Security patches fix vulnerabilities in:
- Operating systems (EC2 nodes, bastion, Jenkins)
- Container base images (Docker images in ECR)
- Kubernetes (EKS version updates)
- Databases (Aurora minor versions)
- npm packages (application code)

Unpatched systems are the #1 cause of security breaches. This runbook ensures patches are applied safely without downtime.

---

## 1. Patching Overview — What Gets Patched and How

| Component | How Patched | Frequency | Downtime |
|-----------|------------|-----------|---------|
| Application code (npm) | CI pipeline (Trivy blocks HIGH CVEs) | Every deployment | Zero |
| Docker base images | Rebuild images in CI pipeline | Weekly | Zero (rolling update) |
| EKS node OS | Node group rolling update | Monthly | Zero (nodes replaced one at a time) |
| EKS Kubernetes version | `eksctl upgrade cluster` | Quarterly | Zero |
| Aurora PostgreSQL minor version | `auto_minor_version_upgrade = true` | Automatic | ~30 seconds (failover) |
| ElastiCache Redis engine | Manual via AWS CLI | Quarterly | ~1-2 minutes |
| EC2 Bastion OS | SSM Run Command | Monthly | None (no traffic) |
| EC2 Jenkins OS | SSM Run Command | Monthly | 5-10 min (no builds during window) |

---

## 2. Application Dependency Patching (Weekly)

### What this covers
npm packages, Node.js version, TypeScript version in all 6 services and frontend.

### Process (automated via CI pipeline)

```
Every code push → CI pipeline runs → Trivy scans the built Docker image
If CRITICAL vulnerabilities ≥ 5 → pipeline FAILS → developer must fix
```

### Manual check for outdated packages

```bash
cd 02-Application-Code/services/user-service

# See what's outdated
npm outdated

# Update all packages to latest compatible versions
npm update

# Check for known security vulnerabilities
npm audit

# Fix automatically fixable issues
npm audit fix

# Commit the updated package-lock.json
git add package-lock.json
git commit -m "chore(deps): update npm dependencies for security patches"
```

### Repeat for all services

```bash
for service in user product cart order payment notification; do
  echo "Patching $service..."
  cd 02-Application-Code/services/${service}-service
  npm audit fix
  cd -
done

cd 02-Application-Code/frontend
npm audit fix
cd -
```

---

## 3. Docker Base Image Patching (Weekly)

### What this covers
The `FROM node:20-alpine` base image in each Dockerfile picks up OS-level patches.

### Process

```bash
# Pull latest base images
docker pull node:20-alpine
docker pull node:20-slim  # if used

# Rebuild all service images (this forces fresh base image layers)
cd 02-Application-Code

# Rebuild each service
for service in frontend services/user-service services/product-service \
               services/cart-service services/order-service \
               services/payment-service services/notification-service; do
  SERVICE_NAME=$(basename $service)
  docker build -t pip-project-ecommerce/${SERVICE_NAME}:patched $service
done

# Run Trivy scan on rebuilt images
for service in frontend user-service product-service cart-service \
               order-service payment-service notification-service; do
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:0.56.2 image \
    --severity CRITICAL,HIGH \
    pip-project-ecommerce/${service}:patched
done
```

If scans are clean, push through the normal CI pipeline for deployment.

---

## 4. EKS Node Group OS Patching (Monthly)

### Why EKS nodes need patching

EKS worker nodes run Amazon Linux 2023 with the Kubernetes kubelet agent. AWS releases new **EKS Optimized AMIs** monthly with OS patches and kubelet updates. We replace old nodes with new ones running the latest AMI.

### How it works (zero downtime — rolling replacement)

```
Old node:  [pod A] [pod B] [pod C]
                 │
                 ▼
Step 1: New node joins with updated AMI
New node:  [ empty ]

Step 2: Old node is cordoned (no new pods scheduled)
Old node:  [pod A] [pod B] [pod C]  ← no new pods
New node:  [ empty ]

Step 3: Pods are evicted from old node (PodDisruptionBudget ensures at least 1 replica stays up)
Old node:  [ empty ]
New node:  [pod A] [pod B] [pod C]  ← moved here

Step 4: Old node is terminated
```

### Step-by-step process

```bash
# Step 1: Get current node group AMI version
aws eks describe-nodegroup \
  --cluster-name pip-project-ecommerce-cluster \
  --nodegroup-name pip-project-ecommerce-workers \
  --region us-east-1 \
  --query 'nodegroup.releaseVersion'

# Step 2: Check if there's a newer AMI available
aws eks describe-addon-versions \
  --kubernetes-version 1.32 \
  --region us-east-1 \
  --query 'addons[0].addonVersions[0].compatibilities[0].clusterVersion'

# Step 3: Trigger rolling update of the node group
# This replaces nodes one at a time with the latest AMI
aws eks update-nodegroup-version \
  --cluster-name pip-project-ecommerce-cluster \
  --nodegroup-name pip-project-ecommerce-workers \
  --region us-east-1

# Step 4: Monitor the update progress
aws eks describe-update \
  --name pip-project-ecommerce-cluster \
  --update-id <UPDATE_ID_FROM_PREVIOUS_COMMAND> \
  --region us-east-1

# Step 5: Watch nodes being replaced
watch kubectl get nodes
# You'll see old nodes go NotReady, then be replaced by new nodes

# Step 6: Verify all pods are still running
kubectl get pods -n ecommerce
```

### Duration

Node group rolling update takes approximately 15-20 minutes per node (3 nodes = ~45-60 minutes total).

---

## 5. Kubernetes Version Upgrade (Quarterly)

### Important rule: only upgrade one minor version at a time

```
Current: 1.30 → Upgrade to: 1.31 (not 1.32 directly)
Then: 1.31 → 1.32
Then: 1.32 → 1.33
```

### Process

```bash
# Step 1: Check current version
kubectl version --short

# Step 2: Check what's available
aws eks describe-addon-versions \
  --region us-east-1 \
  --query 'addons[0].addonVersions[0].compatibilities[0].clusterVersion'

# Step 3: Update the control plane FIRST (not nodes yet)
aws eks update-cluster-version \
  --name pip-project-ecommerce-cluster \
  --kubernetes-version 1.33 \
  --region us-east-1

# Step 4: Wait for control plane update (~10 minutes)
aws eks wait cluster-active \
  --name pip-project-ecommerce-cluster \
  --region us-east-1

# Step 5: Update add-ons to compatible versions
aws eks update-addon \
  --cluster-name pip-project-ecommerce-cluster \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE \
  --region us-east-1

aws eks update-addon \
  --cluster-name pip-project-ecommerce-cluster \
  --addon-name coredns \
  --resolve-conflicts OVERWRITE \
  --region us-east-1

aws eks update-addon \
  --cluster-name pip-project-ecommerce-cluster \
  --addon-name kube-proxy \
  --resolve-conflicts OVERWRITE \
  --region us-east-1

# Step 6: Update node groups (one at a time)
aws eks update-nodegroup-version \
  --cluster-name pip-project-ecommerce-cluster \
  --nodegroup-name pip-project-ecommerce-workers \
  --region us-east-1

# Step 7: After node group completes, update Terraform
# Edit: 01-Infrastructure/environments/prod/prod.tfvars
# Change: eks_cluster_version = "1.33"
# Then: terraform apply -var-file=prod.tfvars -target=module.eks

# Step 8: Verify
kubectl get nodes
# All nodes should show the new version
```

---

## 6. Aurora PostgreSQL Minor Version Patching (Automatic)

Aurora handles minor version patches automatically because `auto_minor_version_upgrade = true` is set in Terraform.

### When automatic patching runs

Patching runs during the configured maintenance window:
- **Window:** Sunday 04:00–05:00 UTC
- **What happens:** Writer instance restarts (~30 seconds), RDS Proxy transparently reconnects

### Verify auto-upgrade is enabled

```bash
aws rds describe-db-instances \
  --db-instance-identifier pip-project-ecommerce-writer \
  --region us-east-1 \
  --query 'DBInstances[0].AutoMinorVersionUpgrade'

# Expected: true
```

### Manual major version upgrade (when needed)

```bash
# Upgrade from Aurora PostgreSQL 17 to 18 (when available)
aws rds modify-db-cluster \
  --db-cluster-identifier pip-project-ecommerce-cluster \
  --engine-version 18.x \
  --allow-major-version-upgrade \
  --apply-immediately \
  --region us-east-1

# This causes ~5-10 minutes downtime — plan a maintenance window
```

---

## 7. EC2 Instance Patching (Monthly — Bastion + Jenkins)

Using AWS Systems Manager (SSM) — no SSH needed.

```bash
# Create a patch baseline (run once to set up)
aws ssm create-patch-baseline \
  --name pip-project-ecommerce-linux-baseline \
  --operating-system AMAZON_LINUX_2023 \
  --approval-rules '{"PatchRules":[{"PatchFilterGroup":{"PatchFilters":[{"Key":"SEVERITY","Values":["Critical","Important"]}]},"ApproveAfterDays":3}]}' \
  --region us-east-1

# Run patching on bastion and Jenkins
aws ssm send-command \
  --document-name "AWS-RunPatchBaseline" \
  --targets "Key=tag:Project,Values=pip-project-ecommerce" \
  --parameters '{"Operation":["Install"]}' \
  --region us-east-1

# Check patch status
aws ssm list-command-invocations \
  --command-id <COMMAND_ID> \
  --details \
  --region us-east-1

# After patching, reboot if required
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Project,Values=pip-project-ecommerce" \
  --parameters 'commands=["needs-restarting -r && sudo reboot || echo no reboot needed"]' \
  --region us-east-1
```

---

## 8. Patching Verification Checklist

Run this after every patching activity:

```bash
# 1. All pods still running?
kubectl get pods -n ecommerce | grep -v Running
# Expected: empty output (all pods Running)

# 2. All health endpoints responding?
for port in 4001 4002 4003 4004 4005 4006; do
  echo -n "Port $port: "
  kubectl run -it --rm test-pod --image=curlimages/curl --restart=Never -n ecommerce \
    -- curl -sf http://$(kubectl get svc -n ecommerce -o jsonpath="{.items[?(@.spec.ports[0].port==$port)].spec.clusterIP}"):$port/health \
    2>/dev/null | jq -r .status
done

# 3. Aurora still available?
aws rds describe-db-clusters \
  --db-cluster-identifier pip-project-ecommerce-cluster \
  --query 'DBClusters[0].Status' \
  --region us-east-1
# Expected: "available"

# 4. No new GuardDuty findings?
aws guardduty list-findings \
  --detector-id $(aws guardduty list-detectors --query 'DetectorIds[0]' --output text --region us-east-1) \
  --finding-criteria '{"Criterion":{"severity":{"Gte":7}}}' \
  --region us-east-1
# Expected: empty FindingIds list

# 5. Smoke test
curl -I https://ecommerce-pip.com
# Expected: HTTP/2 200
```

---

## 9. Patching Calendar

| Month | Activity | Duration | Window |
|-------|----------|----------|--------|
| Every week | npm audit fix + Docker image rebuild | 30 min CI | Automatic |
| Every month | EKS node OS patching | 60 min | Sun 04:00 UTC |
| Every month | EC2 (Bastion + Jenkins) patching | 30 min | Sun 04:00 UTC |
| Every quarter | EKS Kubernetes version upgrade | 2 hours | Planned maintenance |
| Every quarter | ElastiCache Redis version update | 30 min | Sun 04:00 UTC |
| As released | Aurora minor version (automatic) | 30 sec | Sun 04:00 UTC |
| As needed | Aurora major version upgrade | 2 hours | Planned maintenance |

---

*Document version: 1.0 | Project: pip-project-ecommerce*
