# 05-Documents — Project Documentation Index

**Project:** pip-project-ecommerce  
**Type:** Multi-tenant SaaS E-Commerce on AWS EKS

This folder contains all documentation required for the project rubric. Start here.

---

## Document Map

```
05-Documents/
│
├── README.md              ← You are here — start here
├── mentor-signoff.md      ← Print and get signed FIRST (rubric item 1.8)
├── architecture.md        ← Full system design + draw.io diagram prompt
├── slo-sla.md             ← Service level objectives, RTO/RPO, 22 alarms list
├── cost-model.md          ← Monthly cost ~$1,534/month (well under $5,000 budget)
├── disaster-recovery.md   ← Step-by-step DR playbook — what to do when region fails
└── runbooks/
    ├── incident-response.md   ← What to do when something breaks (5 scenarios)
    ├── scaling-procedures.md  ← How to scale pods, nodes, Aurora, Redis
    └── patching.md            ← How to patch OS, K8s, Aurora, npm packages
```

---

## Rubric Coverage Map

### Task 1 — Architecture & Design (8 points)

| Rubric Item | Document | Section |
|------------|---------|---------|
| 1. Multi-tenant SaaS 3-tier architecture | architecture.md | Section 1, 2 |
| 2. Architecture diagram (draw.io) | architecture.md | Section 12 |
| 3. Disaster recovery plan | architecture.md | Section 10 |
| 4. SLO/SLA: 99.95%, <200ms, <1hr RTO | slo-sla.md | Sections 1-5 |
| 5. Security: WAF, VPC flow logs, GuardDuty | architecture.md | Section 8 |
| 6. Cost model: <$5,000/month | cost-model.md | Sections 1-5 |
| 7. Operational runbooks | runbooks/ | All 3 files |
| 8. Mentor sign-off | mentor-signoff.md | Full document |

### Task 3 — Infrastructure (9 points)

| Rubric Item | Where Implemented | Evidence |
|------------|-----------------|---------|
| 1. VPC 3-tier subnets 3 AZs | `01-Infrastructure/modules/networking/main.tf` | public/private/database subnets |
| 2. Aurora Multi-AZ + 2 readers | `01-Infrastructure/modules/aurora/main.tf` | aurora_reader_count=2 |
| 3. EKS 6+ tasks across 3 AZs | `01-Infrastructure/environments/prod/main.tf` | workers_desired=3, 14+ pods |
| 4. ALB health checks + stickiness + logging | `03-Kubernetes/frontend/ingress.yaml` | annotations |
| 5. Auto Scaling CPU/memory | `03-Kubernetes/*/hpa.yaml` + Cluster Autoscaler | 70% trigger |
| 6. 20+ CloudWatch alarms | `01-Infrastructure/modules/monitoring/main.tf` | 22 alarms |
| 7. CloudWatch Logs centralised | `01-Infrastructure/modules/security/main.tf` | log groups |
| 8. EBS snapshots to S3 | `01-Infrastructure/modules/monitoring/main.tf` | DLM policy |
| 9. Cross-region replication | `01-Infrastructure/modules/aurora/global-database.tf` | Global DB |

---

## How to Read the Architecture Diagram

1. Open [app.diagrams.net](https://app.diagrams.net)
2. Click **New Diagram** → **Blank**
3. Click **Extras** → **Edit Diagram**
4. Copy the XML from `architecture.md` Section 12
5. Paste it and click **OK**

The diagram shows the full traffic flow:
```
Internet → Route53 → WAF → External ALB → EKS → Internal ALB → Services → Aurora/Redis
```

---

## Quick Reference: Key Numbers

| Metric | Value | Where Defined |
|--------|-------|--------------|
| Availability SLO | 99.95% | slo-sla.md |
| Latency p99 | < 200ms | slo-sla.md |
| RTO | < 2 minutes | slo-sla.md |
| RPO | < 1 hour | slo-sla.md |
| Monthly cost (prod) | ~$1,534 | cost-model.md |
| Monthly budget | $5,000 | cost-model.md |
| CloudWatch alarms | 22 total | slo-sla.md + monitoring module |
| EKS min nodes | 3 (prod) | prod.tfvars |
| EKS max nodes | 10 (prod) | prod/main.tf |
| Aurora backups | 35 days | aurora/variables.tf |

---

*All documents last updated: 2026 | Project: pip-project-ecommerce*
