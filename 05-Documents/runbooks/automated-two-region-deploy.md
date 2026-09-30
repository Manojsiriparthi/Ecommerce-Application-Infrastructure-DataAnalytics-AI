# Automated Two-Region Deploy — One Command Per Region

This is the end-to-end workflow for destroying and rebuilding the whole platform
(primary **us-east-1** + DR **us-west-2**) with **no manual `kubectl annotate`,
no `aws ssm put-parameter`, no `aws secretsmanager create-secret`, and no
"already exists" errors**. Everything the DR region needs is now created by
Terraform, and the app-side scripts are region-aware.

> All commands run on the **EC2 server** (the box that has Terraform, kubectl,
> aws CLI, and the state backend). The Kiro workspace on your laptop is a
> separate machine — keep them in sync via git (see "Keeping code in sync").

---

## What was automated (so you never hand-fix it again)

| Problem you hit manually today | Permanent fix in code |
|---|---|
| DR pods: `AssumeRoleWithWebIdentity AccessDenied` | Deploy script auto-selects `-dr-services-role` for us-west-2 and renders the ServiceAccount to a temp file (`02-deploy-app.sh`). |
| DR pods: `Invalid parameters: /.../app/jwt-secret` and `Failed fetching secret /.../redis/auth-token` | `dr-app-secrets.tf` creates all app secrets + SSM params in us-west-2 via `aws.dr`. |
| DR role couldn't read `pip-project-ecommerce/...` secrets | `iam-irsa/main.tf` policy now includes base-name ARNs (`pip-project-ecommerce-*`, `.../*`). |
| ALB: `InvalidSubnetID.NotFound` (wrong region's subnets) | Ingresses render to temp files with per-region subnets (`02-deploy-app.sh`); source keeps placeholders. |
| Re-apply: `ResourceAlreadyExistsException` on CloudWatch log groups | `00-pre-apply-cleanup.sh` deletes survivors in both regions; `imports.tf` no longer needs toggling. |
| Prisma `P1001` when creating tables | `01-setup-databases.sh` uses the Aurora **writer** endpoint first, not the proxy. |
| Empty storefront (manual node seed) | `01-setup-databases.sh` Step 4b seeds products via a pod (`npm run seed`). |

---

## Prerequisites (set once per shell)

```bash
export TF_VAR_db_master_password='PipEcom2026#Dev'
export TF_VAR_jwt_secret='<your-jwt-secret>'
export TF_VAR_internal_service_key='<your-internal-key>'
export TF_VAR_redis_auth_token='<your-redis-auth-token>'
```

`enable_global_db = true` and `deletion_protection = true` are already set in
`prod.tfvars`. The DR secrets in `dr-app-secrets.tf` are gated on
`enable_global_db`, so they are created exactly when the DR region is in use.

---

## Full rebuild — clean destroy → apply → app

### 0. (Only when re-applying after a destroy) Clean survivors
```bash
./06-Scripts/00-pre-apply-cleanup.sh
```
Deletes leftover CloudWatch log groups, query definitions, and orphaned WAF/ALB
logs S3 buckets in **both** regions. Prints guidance if an Aurora global cluster
survived an interrupted destroy.

### 1. Apply infrastructure (both regions, one command)
```bash
./06-Scripts/04-terraform-apply.sh prod us-east-1
```
Phased apply: core infra + EKS (both regions) → kubeconfig → Helm addons →
final catch-all (creates `dr-app-secrets.tf`, DR db-url params, everything else).

### 2. Create databases + tables + seed (primary)
```bash
./06-Scripts/01-setup-databases.sh prod us-east-1
```
Creates the 5 service databases, runs Prisma `db push` for all services, seeds
the product catalog, and verifies tables. All via in-cluster pods (Aurora is
private). Uses the **writer** endpoint automatically.

> DR needs no separate DB setup: the Aurora **Global Database** replicates all
> data to us-west-2 automatically. The DR secondary is read-only until failover.

### 3. Deploy the app — primary
```bash
./06-Scripts/02-deploy-app.sh prod us-east-1
```

### 4. Deploy the app — DR (fully automated now)
```bash
aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region us-west-2
./06-Scripts/02-deploy-app.sh prod us-west-2
```
The script auto-picks the DR IRSA role, DR subnets, and DR secrets. No manual
annotate/SSM/secret steps.

### 5. Wire DR failover records — AUTO-DISCOVERED (no manual tfvars edit)
The ALB hostnames change on every rebuild. Instead of hand-editing
`alb_dns_name` / `dr_alb_dns_name` in `prod.tfvars` (which caused a DNS outage
when the value went stale), re-apply with auto-discovery ON. It reads the live
ALB hostname from the ingress in each region:

```bash
terraform -chdir=01-Infrastructure/environments/prod apply \
  -var-file=prod.tfvars -var discover_alb_from_ingress=true -auto-approve
```

This creates PRIMARY (us-east-1) + SECONDARY (us-west-2) failover records and a
health check that always points at the CURRENT ALBs. Do NOT use
`-target=module.route53_acm` — it drags in WAF and can destroy live DNS records.
Always run a full apply.

> First-ever apply (before the app exists) keeps the flag FALSE (default) so
> Terraform doesn't try to reach a cluster that isn't up yet.

### 6. Failover demo
```bash
./06-Scripts/05-dr-failover-test.sh stop-alb
```

---

## Keeping code in sync (laptop workspace ↔ server)

The Kiro workspace and the EC2 server are **different machines**. Fixes made in
one do not appear in the other until you sync via git:

```bash
# On the server, after code changes land in the repo:
cd ~/Ecommerce-Application-Infrastructure-DataAnalytics-AI
git pull
```

Until this is wired to a shared remote, a rebuild from an unsynced server would
reintroduce the very bugs fixed here. Confirm the remote with `git remote -v`.

---

## Known warm-standby limitation

There is no dedicated ElastiCache in the DR region (cost). `dr-app-secrets.tf`
points the DR `redis/primary-endpoint` at the primary Redis, so DR pods reach it
cross-region. If cross-region SGs block it, cart/session degrade gracefully but
core pages still load. For a full regional failover, stand up a DR ElastiCache
and repoint that SSM value.
