# Disaster Recovery Runbook & Performance Baselines
## pip-project-ecommerce — Production (us-east-1)

---

## RTO / RPO Targets

| Metric | Target | How Achieved |
|--------|--------|--------------|
| **RTO** (Recovery Time Objective) | < 2 minutes | Route53 health check detects failure in 90s (3 × 30s), DNS TTL=60s, DR cluster pre-warmed |
| **RPO** (Recovery Point Objective) | < 1 hour | Aurora Global DB replicates with < 1s lag; daily EBS snapshots |

---

## Failover Procedure

### Step 1: Detect failure
```bash
HC_ID=$(aws ssm get-parameter \
  --name /pip-project-ecommerce/prod/route53/primary-health-check-id \
  --region us-east-1 --query Parameter.Value --output text)

aws route53 get-health-check-status --health-check-id "$HC_ID" \
  --query "HealthCheckObservations[*].{Region:IPAddress,Status:StatusReport.Status}" \
  --output table
```

### Step 2: Force failover (if health check not auto-triggering)
```bash
aws route53 update-health-check --health-check-id "$HC_ID" --disabled
```

### Step 3: Promote Aurora DR secondary (only if full us-east-1 failure)
```bash
aws rds remove-from-global-cluster \
  --global-cluster-identifier pip-project-ecommerce-global \
  --db-cluster-identifier pip-project-ecommerce-cluster-dr \
  --region us-west-2
```

### Step 4: Update SSM DATABASE_URLs to DR writer
```bash
DR_WRITER=$(aws rds describe-db-clusters \
  --db-cluster-identifier pip-project-ecommerce-cluster-dr \
  --region us-west-2 --query "DBClusters[0].Endpoint" --output text)

for SVC in user product cart order payment; do
  aws ssm put-parameter \
    --name "/pip-project-ecommerce/prod/db/${SVC}-url" \
    --value "postgresql://pipadmin:PipEcom2026%23Dev@${DR_WRITER}:5432/${SVC}_db?sslmode=require" \
    --type SecureString --overwrite --region us-west-2
done
```

### Step 5: Scale DR EKS + deploy app
```bash
aws eks update-nodegroup-config \
  --cluster-name pip-project-ecommerce-cluster \
  --nodegroup-name pip-project-ecommerce-workers \
  --scaling-config minSize=3,maxSize=6,desiredSize=3 \
  --region us-west-2

./06-Scripts/02-deploy-app.sh prod us-west-2
```

---

## Test Failover

```bash
# Simulate failure
aws route53 update-health-check --health-check-id "$HC_ID" --disabled
sleep 120
dig pip-ecommerce.com +short   # should return DR ALB IP
curl -I http://pip-ecommerce.com   # should return 200 from DR

# End test
aws route53 update-health-check --health-check-id "$HC_ID" --no-disabled
```

---

## Restore from RDS Snapshot

```bash
# List snapshots
aws rds describe-db-cluster-snapshots \
  --db-cluster-identifier pip-project-ecommerce-cluster \
  --region us-east-1 \
  --query "DBClusterSnapshots[*].{ID:DBClusterSnapshotIdentifier,Time:SnapshotCreateTime}" \
  --output table

# Restore
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier pip-project-ecommerce-restored \
  --snapshot-identifier <snapshot-id> \
  --engine aurora-postgresql --engine-version 17.9 \
  --region us-east-1
```

---

## Performance Baselines

### SLOs
| Metric | Target | Alert |
|--------|--------|-------|
| Availability | ≥ 99.9% | < 99.5% |
| p95 Response Time | ≤ 150ms | > 200ms |
| p99 Response Time | ≤ 500ms | > 1000ms |
| Error Rate (5xx) | < 0.1% | > 1% |
| Aurora CPU | < 50% | > 80% |

### Alarm Count: 26 total
- Aurora: 5 | Redis: 3 | ALB: 5 | EKS: 4 | Security: 3
- Anomaly detection: 4 | GuardDuty: 1 | Route53: 1
