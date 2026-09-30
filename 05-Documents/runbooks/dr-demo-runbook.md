# DR Warm-Standby — Deployment & Failover Demo Runbook
## pip-project-ecommerce

This runbook covers deploying the cross-region DR setup and demonstrating failover
from PRIMARY (us-east-1) to DR (us-west-2).

---

## Architecture

```
              Route53  pip-ecommerce.com
              health check on PRIMARY ALB "/"
              ┌──────────────┴──────────────┐
       PRIMARY (us-east-1)            SECONDARY (us-west-2 DR)
       ┌────────────────┐            ┌────────────────┐
       │ EKS + app      │            │ EKS + app      │
       │ (all traffic)  │            │ (idle standby) │
       └───────┬────────┘            └───────┬────────┘
               │                             │
       ┌───────▼────────┐  replicate<1s ┌───▼────────────┐
       │ Aurora PRIMARY │ ────────────► │ Aurora SECONDARY│
       │ (read + write) │               │ (read-only)     │
       └────────────────┘               └─────────────────┘
                    Aurora Global Database
```

Normal: 100% traffic → primary. DR warm (2 nodes), DB replicating.
Failure: Route53 detects → traffic → DR → promote DB → scale nodes → serving.

---

## Part 1 — Deploy the Infrastructure (one apply, both regions)

```bash
cd 01-Infrastructure/environments/prod

# Connect kubeconfig for BOTH clusters (needed by helm.dr/kubernetes.dr providers)
aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region us-east-1
aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region us-west-2

# Apply everything — primary + DR
terraform apply --auto-approve -var-file=prod.tfvars
```

This builds: primary + DR VPCs, EKS clusters + addons, Aurora Global DB
(primary + secondary), WAF (both regions), IAM/IRSA, Route53, monitoring.

> Note: enabling Global DB recreates the primary Aurora. Re-seed after.

---

## Part 2 — Deploy the App to PRIMARY (us-east-1)

```bash
./06-Scripts/02-deploy-app.sh prod us-east-1
```

Then create databases + tables + seed products (as before):
```bash
# Fix SG rule if needed, run prisma db push inside pods, seed 10 products
# (see prior steps — same as original primary bring-up)
```

---

## Part 3 — Deploy the App to DR (us-west-2)

Same script, different region. `ENV=prod` works for both (regional resources
share the `prod` tag; only IAM/S3 use `-dr` for global uniqueness).

```bash
./06-Scripts/02-deploy-app.sh prod us-west-2
```

The DR Aurora is READ-ONLY until failover, so:
- Products page loads (read works, once replicated from primary)
- Register/login writes fail until DR is promoted — expected for warm standby

Get the DR external ALB DNS:
```bash
aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region us-west-2
kubectl get ingress frontend-external-ingress -n ecommerce \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

---

## Part 4 — Wire DR ALB into Route53 Failover

Set the DR ALB DNS in tfvars, then apply route53 only:

```bash
# Put the DR ALB DNS from Part 3 into prod.tfvars
#   dr_alb_dns_name = "internal-k8s-...us-west-2.elb.amazonaws.com"

cd 01-Infrastructure/environments/prod
terraform apply -var-file=prod.tfvars -target=module.route53_acm
```

This creates the PRIMARY/SECONDARY failover A-records + health check.

---

## Part 5 — DEMO: Trigger Failover

```bash
# 1. Show normal state — traffic on primary
./06-Scripts/05-dr-failover-test.sh status

# 2. Simulate primary failure (disables primary health check)
./06-Scripts/05-dr-failover-test.sh failover

# 3. Watch DNS switch to DR (~1-2 min)
watch -n 10 'dig +short pip-ecommerce.com'

# 4. Promote DR Aurora to writable
./06-Scripts/05-dr-failover-test.sh promote

# 5. Scale DR nodes for full load
./06-Scripts/05-dr-failover-test.sh scaleup

# 6. Open browser → pip-ecommerce.com now served from us-west-2
```

---

## Part 6 — Restore Primary (end demo)

```bash
./06-Scripts/05-dr-failover-test.sh restore
watch -n 10 'dig +short pip-ecommerce.com'   # traffic returns to primary
```

---

## RTO / RPO

| Metric | Target | Mechanism |
|--------|--------|-----------|
| RTO | < 2 min | Route53 health check 90s + DNS TTL 60s |
| RPO | < 1 sec | Aurora Global DB continuous replication |

---

## Cost note (warm standby)

DR runs minimal always-on: 2× t3.small + 1× t3.micro EKS + Aurora secondary
reader. On failover you scale up. This is the cost/readiness balance of
warm standby — cheaper than hot standby (full duplicate), faster than
cold standby (rebuild from backup).
