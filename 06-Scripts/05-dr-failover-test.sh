#!/usr/bin/env bash
# =============================================================================
# DR Failover Test — pip-project-ecommerce
# =============================================================================
# Demonstrates Route53 health-check failover from PRIMARY (us-east-1) to
# DR (us-west-2). Use this to prove the warm-standby DR works.
#
# USAGE:
#   ./06-Scripts/05-dr-failover-test.sh status     # show current routing + health
#   ./06-Scripts/05-dr-failover-test.sh stop-alb   # scale primary frontend to 0 (realistic outage)
#   ./06-Scripts/05-dr-failover-test.sh start-alb  # restore primary frontend
#   ./06-Scripts/05-dr-failover-test.sh failover   # disable primary health check (flag-based)
#   ./06-Scripts/05-dr-failover-test.sh promote    # promote DR Aurora to writable
#   ./06-Scripts/05-dr-failover-test.sh scaleup    # scale DR EKS nodes for full load
#   ./06-Scripts/05-dr-failover-test.sh restore    # re-enable primary health check
#
# TWO WAYS TO TRIGGER FAILOVER:
#   stop-alb  → REAL: primary app down, ALB unhealthy, Route53 fails over (recommended for demo)
#   failover  → FLAG: just disables the health check (faster, less realistic)
#
# HOW FAILOVER WORKS:
#   Route53 pings the PRIMARY ALB "/" every 30s. After 3 failures (90s) it
#   marks the primary unhealthy and starts returning the SECONDARY (DR) record.
#   DNS TTL is 60s so clients pick up the change within ~1-2 minutes total.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[DR]${NC}  $1"; }
success() { echo -e "${GREEN}[DR]${NC}  ✓ $1"; }
warn()    { echo -e "${YELLOW}[DR]${NC}  ⚠ $1"; }
fail()    { echo -e "${RED}[DR]${NC}  ✗ $1"; exit 1; }
header()  { echo -e "\n${BOLD}══ $1 ══${NC}"; }

ACTION="${1:-status}"
PROJECT="pip-project-ecommerce"
PRIMARY_REGION="us-east-1"
DR_REGION="us-west-2"
DOMAIN="pip-ecommerce.com"
CLUSTER_NAME="${PROJECT}-cluster"

# ── Resolve health check ID from SSM (set by route53-acm module) ─────────────
get_health_check_id() {
  aws ssm get-parameter \
    --name "/${PROJECT}/prod/route53/primary-health-check-id" \
    --region "$PRIMARY_REGION" \
    --query Parameter.Value --output text 2>/dev/null || echo ""
}

# ── Resolve hosted zone ID ────────────────────────────────────────────────────
get_zone_id() {
  aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
    --output text 2>/dev/null | cut -d'/' -f3 || echo ""
}

# =============================================================================
# STATUS — show current routing, health, and where traffic is going
# =============================================================================
if [[ "$ACTION" == "status" ]]; then
  header "DR Failover Status"

  HC_ID=$(get_health_check_id)
  ZONE_ID=$(get_zone_id)

  echo ""
  info "Domain:            $DOMAIN"
  info "Hosted Zone:       ${ZONE_ID:-NOT FOUND}"
  info "Primary Health Check ID: ${HC_ID:-NOT FOUND}"
  echo ""

  # Health check status
  if [[ -n "$HC_ID" ]]; then
    header "Primary ALB Health Check"
    aws route53 get-health-check-status \
      --health-check-id "$HC_ID" \
      --query "HealthCheckObservations[*].{Checker:Region,Status:StatusReport.Status}" \
      --output table 2>/dev/null || warn "Could not fetch health check status"
  fi

  # What does the domain currently resolve to?
  header "Current DNS Resolution"
  info "Resolving $DOMAIN ..."
  RESOLVED=$(dig +short "$DOMAIN" 2>/dev/null | head -3 || echo "")
  echo "$RESOLVED" | sed 's/^/    /'
  echo ""

  # Failover record set states
  header "Route53 Failover Records"
  if [[ -n "$ZONE_ID" ]]; then
    aws route53 list-resource-record-sets \
      --hosted-zone-id "$ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${DOMAIN}.' && Type=='A'].{SetId:SetIdentifier,Failover:Failover,Target:AliasTarget.DNSName}" \
      --output table 2>/dev/null || warn "No failover records found"
  fi

  # Pod status in both regions
  header "Pod Status — Primary (us-east-1)"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$PRIMARY_REGION" 2>/dev/null || true
  kubectl get pods -n ecommerce --no-headers 2>/dev/null | awk '{print "    "$1"  "$3}' || warn "Primary unreachable"

  header "Pod Status — DR (us-west-2)"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$DR_REGION" 2>/dev/null || true
  kubectl get pods -n ecommerce --no-headers 2>/dev/null | awk '{print "    "$1"  "$3}' || warn "DR unreachable"

  echo ""
  success "Status check complete"
  echo ""
  echo "  To simulate a failover: $0 failover"
fi

# =============================================================================
# FAILOVER — simulate primary region failure
# =============================================================================
if [[ "$ACTION" == "failover" ]]; then
  header "Simulating PRIMARY region failure"

  HC_ID=$(get_health_check_id)
  [[ -z "$HC_ID" ]] && fail "Health check ID not found in SSM. Is Route53 failover configured?"

  echo ""
  warn "This disables the PRIMARY health check → Route53 will route to DR."
  echo -ne "${YELLOW}Continue? [y/N]: ${NC}"
  read -r CONFIRM
  [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Aborted."; exit 0; }

  info "Disabling primary health check ($HC_ID)..."
  aws route53 update-health-check \
    --health-check-id "$HC_ID" \
    --disabled \
    --region "$PRIMARY_REGION" >/dev/null \
    && success "Primary health check DISABLED — Route53 sees primary as unhealthy" \
    || fail "Could not disable health check"

  echo ""
  info "Route53 will now fail over to DR within ~90 seconds (3 checks × 30s)."
  info "DNS TTL is 60s, so total client switchover ~1-2 minutes."
  echo ""
  info "Watch the switch happen:"
  echo "    watch -n 10 'dig +short $DOMAIN'"
  echo ""
  info "Once DNS points to the DR ALB, promote the DR database:"
  echo "    $0 promote"
  echo ""
  info "And scale up DR nodes for full production load:"
  echo "    $0 scaleup"
fi

# =============================================================================
# STOP-ALB — realistic failure: scale primary app to 0 so ALB targets go
# unhealthy → Route53 health check fails → automatic failover to DR.
# This simulates "the primary application is down" more realistically than
# disabling the health check (which just flips a flag).
# =============================================================================
if [[ "$ACTION" == "stop-alb" ]]; then
  header "Simulating PRIMARY app outage (scale frontend to 0)"

  echo ""
  warn "This scales the PRIMARY frontend to 0 replicas."
  warn "The ALB will have no healthy targets → Route53 health check fails →"
  warn "traffic automatically fails over to the DR region."
  echo -ne "${YELLOW}Continue? [y/N]: ${NC}"
  read -r CONFIRM
  [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Aborted."; exit 0; }

  info "Connecting to PRIMARY cluster (us-east-1)..."
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$PRIMARY_REGION" >/dev/null 2>&1 \
    || fail "Could not connect to primary cluster"

  info "Scaling frontend to 0 replicas..."
  kubectl scale deployment/frontend-deployment --replicas=0 -n ecommerce \
    && success "Primary frontend scaled to 0 — ALB targets going unhealthy" \
    || fail "Could not scale frontend"

  echo ""
  info "Route53 health check will fail within ~90s (3 checks × 30s)."
  info "Then DNS switches to DR. Watch it:"
  echo "    watch -n 10 'dig +short $DOMAIN'"
  echo ""
  info "Then promote DR DB + scale DR nodes:"
  echo "    $0 promote"
  echo "    $0 scaleup"
  echo ""
  info "To restore primary later:"
  echo "    $0 start-alb"
fi

# =============================================================================
# START-ALB — restore primary app (scale frontend back up)
# =============================================================================
if [[ "$ACTION" == "start-alb" ]]; then
  header "Restoring PRIMARY app (scale frontend back to 1)"

  info "Connecting to PRIMARY cluster (us-east-1)..."
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$PRIMARY_REGION" >/dev/null 2>&1 \
    || fail "Could not connect to primary cluster"

  info "Scaling frontend back to 1 replica..."
  kubectl scale deployment/frontend-deployment --replicas=1 -n ecommerce \
    && success "Primary frontend restored" \
    || fail "Could not scale frontend"

  info "Waiting for pod to be ready..."
  kubectl rollout status deployment/frontend-deployment -n ecommerce --timeout=120s 2>/dev/null || true

  echo ""
  info "Once ALB targets are healthy (~1-2 min), Route53 routes back to primary."
  info "Watch:  watch -n 10 'dig +short $DOMAIN'"
fi

# =============================================================================
# PROMOTE — make DR Aurora writable (failover the Global Database)
# =============================================================================
if [[ "$ACTION" == "promote" ]]; then
  header "Promoting DR Aurora to writable primary"

  GLOBAL_ID="${PROJECT}-global-db"
  DR_CLUSTER="${PROJECT}-cluster-dr"

  echo ""
  warn "This promotes the DR Aurora secondary to be the new writer."
  warn "The Global Database will fail over to us-west-2."
  echo -ne "${YELLOW}Continue? [y/N]: ${NC}"
  read -r CONFIRM
  [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Aborted."; exit 0; }

  info "Failing over Global Database $GLOBAL_ID to $DR_CLUSTER ..."
  aws rds failover-global-cluster \
    --global-cluster-identifier "$GLOBAL_ID" \
    --target-db-cluster-identifier "arn:aws:rds:${DR_REGION}:$(aws sts get-caller-identity --query Account --output text):cluster:${DR_CLUSTER}" \
    --region "$DR_REGION" >/dev/null 2>&1 \
    && success "Global DB failover initiated — DR Aurora becoming writable" \
    || warn "Failover command failed — check: aws rds describe-global-clusters --global-cluster-identifier $GLOBAL_ID"

  echo ""
  info "Wait for the DR cluster to become writable (~1-2 min):"
  echo "    aws rds describe-db-clusters --db-cluster-identifier $DR_CLUSTER --region $DR_REGION --query 'DBClusters[0].Status'"
fi

# =============================================================================
# SCALEUP — scale DR EKS nodes to handle full production load
# =============================================================================
if [[ "$ACTION" == "scaleup" ]]; then
  header "Scaling up DR EKS nodes for full load"

  NODEGROUP="${PROJECT}-workers"

  info "Scaling DR worker node group to 3 nodes (from 2)..."
  aws eks update-nodegroup-config \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP" \
    --scaling-config minSize=3,maxSize=6,desiredSize=3 \
    --region "$DR_REGION" >/dev/null \
    && success "DR node group scaling to 3 nodes" \
    || warn "Scale-up failed — check nodegroup name: aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $DR_REGION"

  echo ""
  info "Scale the app replicas up too (connect to DR cluster first):"
  echo "    aws eks update-kubeconfig --name $CLUSTER_NAME --region $DR_REGION"
  echo "    kubectl scale deployment --all --replicas=2 -n ecommerce"
fi

# =============================================================================
# RESTORE — re-enable primary, end the test
# =============================================================================
if [[ "$ACTION" == "restore" ]]; then
  header "Restoring PRIMARY region (ending failover test)"

  HC_ID=$(get_health_check_id)
  [[ -z "$HC_ID" ]] && fail "Health check ID not found in SSM"

  info "Re-enabling primary health check ($HC_ID)..."
  aws route53 update-health-check \
    --health-check-id "$HC_ID" \
    --no-disabled \
    --region "$PRIMARY_REGION" >/dev/null \
    && success "Primary health check ENABLED — Route53 will route back to primary" \
    || fail "Could not re-enable health check"

  echo ""
  info "Traffic returns to primary within ~90s once health checks pass."
  info "Verify:"
  echo "    watch -n 10 'dig +short $DOMAIN'"
  echo ""
  warn "NOTE: If you promoted the DR database, the Global DB writer is now in"
  warn "us-west-2. To move it back, run another failover-global-cluster targeting"
  warn "the us-east-1 cluster AFTER it has re-synced as a secondary."
fi
