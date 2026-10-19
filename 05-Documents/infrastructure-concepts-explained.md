# Infrastructure Concepts — Explained Simply
## pip-project-ecommerce

This document explains the main Terraform/AWS concepts used in this project:
what each one is, why we enabled it, what problem it solved, and how it works.

---

## 1. Terraform `null_resource` + `local-exec` — what and why

### What it is
- A `null_resource` is a Terraform resource that creates NOTHING in AWS. It's a
  placeholder you attach actions to.
- `local-exec` is a provisioner that runs a shell command ON THE MACHINE running
  `terraform apply` (your laptop/server), NOT in AWS.

### Where we used it
`modules/eks/main.tf` — `null_resource.update_kubeconfig`:
```hcl
resource "null_resource" "update_kubeconfig" {
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ... --region ..."
  }
}
```

### What problem it solved
After Terraform creates the EKS cluster, the Helm/Kubernetes providers need a
`~/.kube/config` entry to connect. Terraform can't do that natively, so we run
`aws eks update-kubeconfig` via local-exec automatically.

### Why we REMOVED it from the aurora module
We originally had a `null_resource.db_setup` that ran a script to create databases
and tables. It kept HANGING terraform apply for 30+ minutes (waiting for Aurora
proxy warmup + pod scheduling). We removed it and made DB setup a separate script
(`06-Scripts/01-setup-databases.sh`) you run manually. Lesson: local-exec is great
for quick actions, bad for long-running waits inside apply.

### How local-exec triggers work
`triggers = { ... }` — a map of values. When any value changes, the resource
re-runs. We hashed the script content so editing the script re-triggered it.

---

## 2. Aurora Global Database (`enable_global_db = true`)

### What it is
A single logical database spanning two regions:
- PRIMARY cluster (us-east-1) — read + write
- SECONDARY cluster (us-west-2) — read-only replica, < 1s behind

### Why we enabled it
For Disaster Recovery. If us-east-1 goes down entirely, we promote the us-west-2
secondary to become the new writer. All data is already there (replicated
continuously). RPO < 1 second, RTO < 2 minutes.

### How it works in Terraform
```hcl
aws_rds_global_cluster.ecommerce      # the wrapper linking both
aws_rds_cluster.primary               # writer, us-east-1
aws_rds_cluster.secondary (aws.dr)    # replica, us-west-2
```
The primary's `global_cluster_identifier` links it to the global cluster.
The secondary references the same global cluster ID but uses the `aws.dr` provider.

### The catch we hit
Enabling Global DB on an EXISTING standalone cluster forces Terraform to RECREATE
the primary (you can't add global to a running cluster in-place via Terraform).
We accepted this — test data only, re-seeded after.

### KMS requirement
AWS requires an EXPLICIT KMS key in the DR region for the encrypted replica. We
create `aws_kms_key.dr_aurora` with the `aws.dr` provider.

---

## 3. Provider aliases (`aws.dr`, `helm.dr`, `kubernetes.dr`)

### What it is
Terraform normally has ONE aws provider (one region). To manage two regions in
one apply, we declare a second provider with an alias:
```hcl
provider "aws" { region = "us-east-1" }              # default
provider "aws" { alias = "dr"; region = "us-west-2" } # DR
```

### Why we needed it
Aurora Global Database MUST create both clusters in one Terraform state (they
reference each other). A separate folder can't do that cleanly. So DR modules use
`providers = { aws = aws.dr }` to create resources in us-west-2.

### The tricky part — helm/kubernetes aliases
The DR EKS addons (Load Balancer Controller) need to connect to the DR cluster.
We pin each provider to a specific cluster using `config_context`:
```hcl
provider "helm" {
  kubernetes { config_context = "arn:aws:eks:us-east-1:...:cluster/...-cluster" }
}
provider "helm" {
  alias = "dr"
  kubernetes { config_context = "arn:aws:eks:us-west-2:...:cluster/...-cluster" }
}
```
Both clusters share the same NAME but live in different regions, so the ARN
(which includes the region) makes each context unique.

### configuration_aliases
The eks-addons MODULE declares it accepts aliased providers:
```hcl
helm = { source = "hashicorp/helm", configuration_aliases = [helm] }
```
This lets us reuse the SAME module for both primary and DR by passing different
providers.

---

## 4. Route53 health checks + failover routing

### What it is
Route53 continuously pings the primary ALB. Based on health, it decides which
IP to return for `pip-ecommerce.com`.

### How it works
- `aws_route53_health_check.primary` — pings primary ALB `/` every 30s
- Two A records, same name, different `set_identifier`:
  - `failover_routing_policy { type = "PRIMARY" }` + health_check_id → primary ALB
  - `failover_routing_policy { type = "SECONDARY" }` → DR ALB
- Healthy: Route53 returns PRIMARY. 3 failures (90s): returns SECONDARY.

### Why this design
It's fully automatic — no human needed to switch DNS. Combined with DNS TTL of
60s, total failover time is under 2 minutes (meets RTO).

---

## 5. Security Groups — and the EKS auto-SG gotcha

### What it is
Security Groups are stateful firewalls on AWS resources. The Aurora SG controls
who can connect to the database on port 5432.

### The gotcha we hit
EKS creates TWO security groups:
1. The one WE define in Terraform (`eks_sg`)
2. An AUTO-created "cluster security group" that AWS attaches to all nodes

Our Aurora SG only allowed #1. But pods run on nodes using #2. Result: connection
timeouts. Fix — a standalone rule allowing the auto-created SG:
```hcl
resource "aws_security_group_rule" "aurora_allow_eks_nodes" {
  source_security_group_id = module.eks.node_security_group_id  # the auto SG
  security_group_id        = module.networking.aurora_sg_id
  from_port = 5432; to_port = 5432
}
```
We added the same rule for DR (`dr_aurora_allow_eks_nodes` with `aws.dr`).

### Why it's a separate resource (not inline)
The networking module runs BEFORE the eks module. It can't reference the EKS
node SG (would be a circular dependency). So the rule lives in the root main.tf,
which runs after both modules exist.

---

## 6. IAM Roles — global vs cluster-specific

### The key concept
IAM roles are GLOBAL (account-wide), not regional. This affects DR reuse:

**Plain service roles (EKS cluster role, node role) — REUSED across regions.**
They just say "EKS can assume this." No region binding. DR reuses primary's.

**IRSA roles (pod-level) — CANNOT be reused.**
IRSA = IAM Roles for Service Accounts. Their trust policy is locked to ONE
cluster's OIDC provider URL:
```
"Federated": "oidc.eks.us-east-1.amazonaws.com/id/ABC"  ← only primary
```
A DR pod presents a token from the DR OIDC endpoint (`us-west-2.../XYZ`), which
the primary's role rejects. So DR needs its OWN IRSA roles (`iam_irsa_dr`) with a
unique name (`pip-project-ecommerce-dr`) because role names are globally unique.

---

## 7. EKS tags, Kubernetes, subnets — how they connect

### Subnet tags EKS requires
For the AWS Load Balancer Controller to work, subnets must be tagged:
- Public subnets: `kubernetes.io/role/elb = 1` (external ALBs go here)
- Private subnets: `kubernetes.io/role/internal-elb = 1` (internal ALBs go here)
- All subnets: `kubernetes.io/cluster/<cluster-name> = shared`

Without these tags, the controller can't figure out where to place ALBs.

### How subnets map to workloads
- **Public subnets** — External ALB + public EKS node (ALB network interface)
- **Private subnets** — worker nodes (all app pods), internal ALB, ElastiCache
- **Database subnets** — Aurora only (most isolated, no internet route)

### IRSA — how a pod gets AWS permissions
1. Pod uses a Kubernetes ServiceAccount (`ecommerce-services-sa`)
2. That SA is annotated with an IAM role ARN
3. EKS OIDC provider lets the pod exchange its SA token for AWS credentials
4. Pod can now call AWS APIs (read secrets, publish to SNS) — no keys in the pod

---

## 8. Secrets Store CSI Driver

### What problem it solves
Pods need secrets (DATABASE_URL, JWT secret). Putting them in env vars or the
image is insecure. This driver mounts secrets from AWS into pods securely.

### How it works
1. `SecretProviderClass` defines which SSM params / Secrets Manager secrets to fetch
2. The CSI driver (installed via eks-addons) fetches them using the pod's IRSA role
3. It syncs them into a Kubernetes Secret
4. The pod reads them as env vars from that Secret

This is why DATABASE_URL flows: SSM → CSI driver → K8s Secret → pod env var.

---

## 9. EKS Add-ons (the eks-addons module)

### What it installs
- **AWS Load Balancer Controller** — turns Kubernetes Ingress into real ALBs.
  WITHOUT this, applying ingress.yaml creates no ALB. This was the critical
  missing piece for DR.
- **EBS CSI Driver** — lets pods use EBS volumes for persistent storage
- **Secrets Store CSI Driver** — mounts AWS secrets (above)
- **Cluster Autoscaler** — adds/removes nodes based on pod demand
- **Fluent Bit** — ships pod logs to CloudWatch

### Why it's a separate module from EKS
The addons need the OIDC provider (for IRSA) which the EKS cluster creates. To
avoid a circular dependency, addons are a separate module applied after EKS.

---

## 10. CloudWatch — alarms, dashboards, anomaly detection, log retention

### Alarms (26 total)
Static threshold alarms ("CPU > 80%") + ML anomaly-detection alarms
(`ANOMALY_DETECTION_BAND` — learns normal patterns, alerts on deviation).

### Anomaly detection — why it's smarter than static
Static: "alert if requests > 100k" — misses gradual attacks, noisy on weekends.
Anomaly: "alert if requests are unusual FOR THIS TIME OF DAY" — learns the pattern.

### Log retention (rubric requirement)
- Application logs: 30 days (`retention_in_days = 30`)
- Audit logs (CloudTrail, VPC flow): 90 days (`retention_in_days = 90`)
Set on each `aws_cloudwatch_log_group`.

### Logs Insights saved queries
Pre-written queries for common investigations: error-rate trend, slow requests
(p95/p99), DB connection errors, user activity, pod crashes. Saved so anyone can
run them without writing the query.

---

## 11. Lambda functions (07-Lambda)

### Three functions
1. **secrets-rotation** — rotates DB password + JWT secret on schedule (EventBridge cron)
2. **ebs-snapshot-backup** — daily EBS snapshots of EKS nodes, 7-day retention
3. **sns-to-slack** — forwards CloudWatch alarms to Slack/PagerDuty

### How they're triggered
- EventBridge scheduled rules (cron) for rotation + backup
- SNS subscription for the Slack forwarder

### Least-privilege IAM
Each Lambda has its own IAM policy granting ONLY what it needs (e.g. the backup
Lambda can create snapshots but can only DELETE snapshots it created — tag-scoped).

---

## 12. `terraform import` blocks (imports.tf)

### What problem it solves
CloudWatch log groups survive `terraform destroy` (AWS keeps them). On the next
apply, Terraform tries to CREATE them and fails with "already exists".

### How import blocks fix it
```hcl
import {
  to = module.security.aws_cloudwatch_log_group.vpc_flow_logs
  id = "/aws/vpc/flowlogs/pip-project-ecommerce-prod"
}
```
This tells Terraform "if this exists, ADOPT it into state instead of creating."
Permanently fixes the ResourceAlreadyExistsException.

---

## Key Design Principles Summary

| Concept | Why we used it |
|---------|----------------|
| null_resource + local-exec | Auto-run kubeconfig update after EKS create |
| Aurora Global DB | Cross-region DR, < 1s replication |
| Provider aliases (aws.dr) | Manage 2 regions in one state (Global DB needs it) |
| Route53 failover | Automatic region failover, no human needed |
| Standalone SG rule | Fix EKS auto-created node SG → Aurora access |
| Separate IRSA per cluster | IRSA trust policy is cluster-specific |
| Subnet tags | LB Controller needs them to place ALBs |
| Secrets Store CSI | Secure secret delivery to pods |
| eks-addons module | LB Controller = no ALB without it |
| Anomaly detection | Smarter than static thresholds |
| Import blocks | Fix log-group already-exists on re-apply |
