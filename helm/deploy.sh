#!/usr/bin/env bash
# ============================================================
# helm/deploy.sh
# Deploys all Helm charts in dependency order.
# Run from the project root after cluster bootstrap.
# Prerequisites: helm >= 3.12, kubectl configured (via bastion)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- colour helpers ----
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- pre-flight ----
command -v helm   >/dev/null 2>&1 || error "helm not found in PATH"
command -v kubectl >/dev/null 2>&1 || error "kubectl not found in PATH"
kubectl cluster-info >/dev/null 2>&1 || error "kubectl cannot reach cluster — check KUBECONFIG"

# ============================================================
# 1. cert-manager (must come before ingress so webhooks exist)
# ============================================================
info "Adding Helm repos..."
helm repo add jetstack   https://charts.jetstack.io           --force-update
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo add coredns    https://coredns.github.io/helm       --force-update
helm repo update

info "Installing cert-manager..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version "v1.14.5" \
  --values "${SCRIPT_DIR}/cert-manager-values.yaml" \
  --wait \
  --timeout 5m

info "Waiting for cert-manager webhook to be ready..."
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s

# ============================================================
# 2. ingress-nginx
# ============================================================
info "Installing ingress-nginx..."
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --version "4.10.1" \
  --values "${SCRIPT_DIR}/ingress-nginx-values.yaml" \
  --wait \
  --timeout 5m

# ============================================================
# 3. CoreDNS (stand-alone; RKE2 already ships one)
# NOTE: RKE2 manages its own CoreDNS via the rke2-coredns HelmChart
# CR in kube-system. The values in coredns-values.yaml are applied
# via a patch to that HelmChart resource — not a separate install.
# ============================================================
info "Patching RKE2 built-in CoreDNS HelmChart..."
kubectl patch helmchart rke2-coredns -n kube-system --type=merge \
  --patch "$(cat "${SCRIPT_DIR}/coredns-helmchart-patch.yaml")" || \
  warn "CoreDNS HelmChart patch failed — you may need to apply manually. See docs/coredns-guide.md"

# ============================================================
# 4. ClusterIssuer for Let's Encrypt (requires cert-manager)
# Edit the email below before running.
# ============================================================
ACME_EMAIL="${ACME_EMAIL:-changeme@example.com}"
if [[ "${ACME_EMAIL}" == "changeme@example.com" ]]; then
  warn "ACME_EMAIL not set — skipping ClusterIssuer creation."
  warn "Set ACME_EMAIL=your@email.com and re-run to create Let's Encrypt issuers."
else
  info "Creating ClusterIssuers for Let's Encrypt (staging + prod)..."
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            class: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
fi

info "All Helm deployments complete."
info ""
info "Verify deployments:"
info "  kubectl get pods -n cert-manager"
info "  kubectl get pods -n ingress-nginx"
info "  kubectl get nodes"
