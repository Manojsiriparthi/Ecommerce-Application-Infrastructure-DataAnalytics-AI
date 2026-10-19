# Runbook: Scaling Procedures

**Project:** pip-project-ecommerce  
**Purpose:** How to scale the application up and down — manually and automatically  
**Audience:** DevOps engineer, on-call team

---

## Overview: What Can Scale?

```
┌─────────────────────────────────────────────────────┐
│  AUTOMATIC SCALING (no human action needed)         │
│                                                     │
│  Pods:  HPA scales pods when CPU > 70%             │
│  Nodes: Cluster Autoscaler adds nodes when pods    │
│         can't be scheduled                         │
│  ALB:   Scales automatically (AWS-managed)         │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│  MANUAL SCALING (human action required)             │
│                                                     │
│  Aurora: upgrade instance class                    │
│  ElastiCache: upgrade node type                    │
│  Jenkins: upgrade instance type                    │
│  EKS node group min/max limits                     │
└─────────────────────────────────────────────────────┘
```

---

## 1. Automatic Pod Scaling (HPA)

### How it works

```
Every 15 seconds, HPA checks:
  Current CPU usage of all pods in the deployment
        │
        ▼
  Usage > 70% of requested CPU?
        │
  YES ──┤── Add a pod replica (up to max: 10)
        │
  NO  ──┤── Usage < 40% for 5 minutes?
           │
     YES ──┤── Remove a pod replica (down to min: 2)
```

### Check current HPA status

```bash
# See all HPAs and their current state
kubectl get hpa -n ecommerce

# Example output:
# NAME              REFERENCE                          TARGETS   MINPODS   MAXPODS   REPLICAS
# frontend-hpa      Deployment/frontend-deployment     45%/70%   3         10        3
# user-service-hpa  Deployment/user-service-deployment 30%/70%   2         10        2
```

### Manually override pod count (temporary)

```bash
# Scale up a specific service immediately (e.g. before a sale event)
kubectl scale deployment cart-service-deployment --replicas=5 -n ecommerce

# Verify the scale-out worked
kubectl get pods -n ecommerce -l app=cart-service

# IMPORTANT: HPA will override this after a few minutes
# To make it stick, update the HPA minReplicas:
kubectl patch hpa cart-service-hpa -n ecommerce \
  -p '{"spec":{"minReplicas":5}}'
```

### Pre-scaling for a known event (e.g. flash sale)

```bash
# 30 minutes before the event:
# 1. Scale up all services to their expected peak replicas
for svc in user product cart order payment; do
  kubectl scale deployment ${svc}-service-deployment \
    --replicas=6 -n ecommerce
done

kubectl scale deployment frontend-deployment --replicas=6 -n ecommerce

# 2. Temporarily raise HPA minReplicas to prevent scale-in during event
kubectl patch hpa frontend-hpa -n ecommerce \
  -p '{"spec":{"minReplicas":6,"maxReplicas":15}}'

# 3. After the event, restore normal values
kubectl patch hpa frontend-hpa -n ecommerce \
  -p '{"spec":{"minReplicas":3,"maxReplicas":10}}'
```

---

## 2. Automatic Node Scaling (Cluster Autoscaler)

### How it works

```
A pod cannot be scheduled (Pending state — not enough CPU/memory on nodes)
        │
        ▼
Cluster Autoscaler detects Pending pod
        │
        ▼
Requests a new EC2 node from the Auto Scaling Group
        │
        ▼
New node joins the cluster (~3-5 minutes)
        │
        ▼
Pod is scheduled on the new node
```

### Check autoscaler activity

```bash
# Check autoscaler logs
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=cluster-autoscaler \
  --tail=50 | grep -E "scale|node"

# Check current node count
kubectl get nodes

# Check node utilisation
kubectl top nodes
```

### Current node group limits (prod)

| Node Group | Min | Desired | Max |
|-----------|-----|---------|-----|
| workers (private) | 3 | 3 | 10 |
| public (ALB support) | 1 | 1 | 3 |

### Change node group limits permanently

```bash
# Update via AWS CLI (change takes effect immediately)
aws eks update-nodegroup-config \
  --cluster-name pip-project-ecommerce-cluster \
  --nodegroup-name pip-project-ecommerce-workers \
  --scaling-config minSize=5,maxSize=15,desiredSize=5 \
  --region us-east-1

# OR update in Terraform (preferred — keeps IaC in sync):
# Edit 01-Infrastructure/environments/prod/main.tf
# Change workers_min, workers_max, workers_desired values
# Then: terraform apply -var-file=prod.tfvars -target=module.eks
```

---

## 3. Scale Aurora PostgreSQL (Manual)

### When to scale

- CPU > 70% sustained for > 30 minutes
- Connection count consistently near 500 (Proxy limit)
- Write latency > 50ms p99

### Upgrade instance class (minimal downtime ~30 seconds)

```bash
# Upgrade the writer instance
aws rds modify-db-instance \
  --db-instance-identifier pip-project-ecommerce-writer \
  --db-instance-class db.r6g.xlarge \
  --apply-immediately \
  --region us-east-1

# RDS will perform a failover — writer becomes a reader briefly
# RDS Proxy handles the connection transparently (pods won't notice)

# Monitor upgrade progress
aws rds describe-db-instances \
  --db-instance-identifier pip-project-ecommerce-writer \
  --query 'DBInstances[0].DBInstanceStatus' \
  --region us-east-1
```

### Add a Read Replica

```bash
# Add another reader for more read capacity
aws rds create-db-instance \
  --db-instance-identifier pip-project-ecommerce-reader-3 \
  --db-cluster-identifier pip-project-ecommerce-cluster \
  --db-instance-class db.r6g.large \
  --engine aurora-postgresql \
  --region us-east-1
```

### Aurora instance class reference

| Class | vCPU | RAM | Max Connections | Monthly Cost |
|-------|------|-----|----------------|-------------|
| db.t3.medium | 2 | 4GB | ~170 | $52/mo |
| db.r5.large | 2 | 16GB | ~700 | $208/mo |
| db.r6g.large | 2 | 16GB | ~700 | $187/mo |
| db.r6g.xlarge | 4 | 32GB | ~1400 | $374/mo |
| db.r6g.2xlarge | 8 | 64GB | ~2800 | $748/mo |

---

## 4. Scale ElastiCache Redis (Manual)

### When to scale

- CPU > 70% sustained
- Memory > 80%
- Cache eviction rate rising (allkeys-lru evicting too many keys)

### Upgrade ElastiCache node (causes 1-2 minutes failover)

```bash
# Modify the replication group (online modification)
aws elasticache modify-replication-group \
  --replication-group-id pip-project-ecommerce-redis \
  --cache-node-type cache.r6g.xlarge \
  --apply-immediately \
  --region us-east-1

# The replica will be upgraded first, then a failover to it
# Applications using Redis may see ~5 seconds of connection errors
# Ensure app code has Redis retry logic (connect-retry)
```

### Redis node reference

| Node | vCPU | RAM | Max Connections | Monthly Cost |
|------|------|-----|----------------|-------------|
| cache.t3.micro | 2 | 0.5GB | 65k | $12/mo |
| cache.t3.small | 2 | 1.37GB | 65k | $24/mo |
| cache.r6g.large | 2 | 13.07GB | 65k | $166/mo |
| cache.r6g.xlarge | 4 | 26.32GB | 65k | $332/mo |

---

## 5. Scale-In (Reduce Cost After Traffic Drops)

After a peak event, scale back down to save money.

### Scale-in pods

```bash
# Restore normal replica counts
for svc in user product cart order payment notification; do
  kubectl scale deployment ${svc}-service-deployment \
    --replicas=2 -n ecommerce
done

kubectl scale deployment frontend-deployment --replicas=3 -n ecommerce
```

### Scale-in nodes

Cluster Autoscaler handles this automatically after 10 minutes of low utilisation.
To speed it up:

```bash
# Force autoscaler to evaluate immediately
kubectl annotate node <node-name> \
  cluster-autoscaler.kubernetes.io/scale-down-disabled=false

# Check which nodes are candidates for removal
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=cluster-autoscaler \
  --tail=20 | grep "scale_down"
```

---

## 6. Scaling Decision Matrix

Use this table to decide what action to take:

| Symptom | Check | Action |
|---------|-------|--------|
| Response time slow | `kubectl top pods` | HPA should add pods automatically |
| Pods in Pending state | `kubectl describe pod` | Autoscaler should add node; if not, check logs |
| Aurora CPU > 70% | CloudWatch → Aurora CPU alarm | Add read replica or upgrade instance |
| Aurora connections > 400 | CloudWatch → connections alarm | Scale down pod replicas temporarily |
| Redis memory > 80% | CloudWatch → Redis memory alarm | Upgrade Redis node type |
| ALB 5xx errors | ALB metrics in CloudWatch | Check pod health; scale up if needed |
| Everything slow | All metrics elevated | Pre-scale all layers before peak event |

---

*Document version: 1.0 | Project: pip-project-ecommerce*
