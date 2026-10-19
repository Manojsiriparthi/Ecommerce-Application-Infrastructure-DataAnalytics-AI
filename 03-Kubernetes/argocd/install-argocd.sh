#!/usr/bin/env bash
# =============================================================================
# ArgoCD Bootstrap Script
# =============================================================================
# Run this ONCE after `terraform apply` finishes and the EKS cluster is ready.
# This is the only manual step in the entire deployment flow.
# After this runs, every future deployment is fully automated via Git.
#
# PREREQUISITES (already done by infra pipeline):
#   - EKS cluster is running
#   - kubectl is configured (aws eks update-kubeconfig already called)
#   - Helm 3 is installed on this machine
#
# WHAT THIS SCRIPT DOES:
#   1. Creates argocd namespace
#   2. Installs ArgoCD via Helm (pinned version)
#   3. Waits for ArgoCD to be ready
#   4. Gets the initial admin password
#   5. Applies the ArgoCD Application CRD (ecommerce-app.yaml)
#      which tells ArgoCD to watch the main branch of this repo
#   6. From this point: merge to main → ArgoCD auto-deploys to EKS
#
# USAGE:
#   chmod +x install-argocd.sh
#   ./install-argocd.sh
#
# After running, access ArgoCD UI:
#   kubectl port-forward svc/argocd-server -n argocd 8080:443
#   Open: https://localhost:8080
#   Username: admin
#   Password: shown at the end of this script
# =============================================================================
set -euo pipefail

ARGOCD_NAMESPACE="argocd"
ARGOCD_CHART_VERSION="6.7.3"      # Helm chart version — pin deliberately
ARGOCD_APP_VERSION="v2.10.5"      # ArgoCD server version this chart installs
REPO_ROOT="$(git rev-parse --show-toplevel)"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  ArgoCD Bootstrap — pip-project-ecommerce"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Step 1: Create namespace ──────────────────────────────────────────────────
echo "1/6  Creating namespace: ${ARGOCD_NAMESPACE}"
kubectl apply -f "${REPO_ROOT}/03-Kubernetes/argocd/namespace.yaml"

# ── Step 2: Add ArgoCD Helm repo ─────────────────────────────────────────────
echo "2/6  Adding ArgoCD Helm repository..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# ── Step 3: Install ArgoCD ───────────────────────────────────────────────────
echo "3/6  Installing ArgoCD ${ARGOCD_APP_VERSION} (chart ${ARGOCD_CHART_VERSION})..."

helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NAMESPACE}" \
    --version   "${ARGOCD_CHART_VERSION}" \
    --values    "${REPO_ROOT}/03-Kubernetes/argocd/argocd-values.yaml" \
    --wait \
    --timeout 10m

echo "✅ ArgoCD installed."

# ── Step 4: Wait for all pods ready ──────────────────────────────────────────
echo "4/6  Waiting for ArgoCD pods to be ready..."
kubectl wait pod \
    --for=condition=Ready \
    --selector=app.kubernetes.io/name=argocd-server \
    --namespace="${ARGOCD_NAMESPACE}" \
    --timeout=5m

echo "✅ ArgoCD server is ready."

# ── Step 5: Apply Application CRD ────────────────────────────────────────────
echo "5/6  Applying ArgoCD Application manifests..."

kubectl apply -f "${REPO_ROOT}/03-Kubernetes/argocd/project.yaml"
kubectl apply -f "${REPO_ROOT}/03-Kubernetes/argocd/ecommerce-app.yaml"

echo "✅ ArgoCD Application registered."
echo "   ArgoCD will now watch the 'main' branch of the repository."
echo "   Merging a PR to main will automatically deploy to EKS."

# ── Step 6: Print initial admin password ─────────────────────────────────────
echo "6/6  Retrieving initial admin password..."
ADMIN_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
    --namespace "${ARGOCD_NAMESPACE}" \
    -o jsonpath="{.data.password}" | base64 --decode)

echo ""
echo "══════════════════════════════════════════════════════"
echo "  ✅ ArgoCD bootstrap complete!"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Access the ArgoCD UI:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    Open: https://localhost:8080"
echo "    Username: admin"
echo "    Password: ${ADMIN_PASSWORD}"
echo ""
echo "  ⚠️  Change the admin password immediately after first login."
echo "    argocd account update-password"
echo ""
echo "  ArgoCD is watching: main branch → 03-Kubernetes/"
echo "  Merge a PR to main to trigger automatic deployment."
echo ""
