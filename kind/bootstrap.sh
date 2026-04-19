#!/usr/bin/env bash
# =============================================================================
# Bootstrap kind multi-cluster environment
#
# What this script does (the parts that cannot be GitOps'd):
#   1. Create kind clusters — nodes start NotReady without a CNI
#   2. Install Cilium on both — nodes won't become Ready without it, so ArgoCD
#      can't be bootstrapped until Cilium is up
#   3. Install ArgoCD on each cluster independently — each cluster is self-managing
#   4. Exchange Istio remote secrets — must happen after ArgoCD has deployed
#      Istio on both clusters; this is the one cross-cluster manual step,
#      equivalent to seeding secrets in GCP Secret Manager on badgerops
#
# Prerequisites: kind, kubectl, helm, kustomize, istioctl, docker
# Run from the repo root or the kind/ directory.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER1="cluster1"
CLUSTER2="cluster2"
CTX1="kind-${CLUSTER1}"
CTX2="kind-${CLUSTER2}"

CILIUM_VERSION="1.19.0"

log() { echo "[$(date +%H:%M:%S)] $*"; }
ok()  { echo "✓ $*"; }
die() { echo "✗ $*" >&2; exit 1; }

# =============================================================================
# Prerequisites
# =============================================================================
check_prereqs() {
  log "Checking prerequisites..."
  local missing=()
  for cmd in kind kubectl helm kustomize istioctl docker; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing tools: ${missing[*]}"

  helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
  helm repo update cilium >/dev/null
  ok "Prerequisites OK"
}

# =============================================================================
# Clusters
# =============================================================================
create_clusters() {
  log "Creating kind clusters..."

  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER1}$"; then
    echo "  cluster1 already exists, skipping"
  else
    kind create cluster --config "${SCRIPT_DIR}/cluster1.yaml"
  fi

  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER2}$"; then
    echo "  cluster2 already exists, skipping"
  else
    kind create cluster --config "${SCRIPT_DIR}/cluster2.yaml"
  fi

  ok "Clusters created"
}

# =============================================================================
# Cilium — installed directly before ArgoCD bootstrap.
# Nodes remain NotReady without a CNI; ArgoCD pods won't schedule until nodes
# are Ready. kubeProxyReplacement=false keeps standard kube-proxy so Istio's
# iptables interception rules don't conflict with Cilium's eBPF datapath.
# ArgoCD manages Cilium config (upgrades, values changes) going forward.
# =============================================================================
install_cilium() {
  local ctx=$1 cluster=$2
  log "Installing Cilium on ${cluster}..."

  helm upgrade --install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --kube-context "${ctx}" \
    --namespace kube-system \
    --set image.pullPolicy=IfNotPresent \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=false \
    --set operator.replicas=1 \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --wait --timeout=300s

  ok "Cilium ready on ${cluster}"
}

# =============================================================================
# ArgoCD — each cluster gets its own instance managing only itself.
# The ApplicationSet on each cluster watches its own overlay directory so
# neither cluster is a single point of failure for the other.
# =============================================================================
install_argocd() {
  local ctx=$1 overlay=$2
  log "Installing ArgoCD on ${ctx}..."

  kubectl --context="${ctx}" create namespace argocd --dry-run=client -o yaml \
    | kubectl --context="${ctx}" apply --server-side -f -

  # First pass: applies CRDs. ApplicationSet CR will fail (CRD not yet established) — that's expected.
  kustomize build --enable-helm "${REPO_ROOT}/${overlay}" \
    | kubectl --context="${ctx}" apply --server-side -f - || true

  # Wait for ArgoCD CRDs to be established before second pass
  kubectl --context="${ctx}" wait \
    --for=condition=established \
    crd/applications.argoproj.io \
    crd/applicationsets.argoproj.io \
    --timeout=60s

  # Second pass: ApplicationSet CR now applies cleanly
  kustomize build --enable-helm "${REPO_ROOT}/${overlay}" \
    | kubectl --context="${ctx}" apply --server-side -f -

  kubectl --context="${ctx}" wait \
    --for=condition=available deployment/argocd-server \
    -n argocd --timeout=300s

  ok "ArgoCD ready on ${ctx}"
}

# =============================================================================
# Detect the kind Docker network and update MetalLB overlay files to match.
# OrbStack, Docker Desktop, and Lima all use different default subnets.
# =============================================================================
patch_metallb_ranges() {
  local kind_cidr base pool1 pool2
  kind_cidr=$(docker network inspect kind --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)
  [[ -z "${kind_cidr}" ]] && return

  base=$(echo "${kind_cidr}" | cut -d. -f1-3)   # e.g. 192.168.97
  pool1="${base}.200-${base}.210"
  pool2="${base}.220-${base}.230"

  log "Detected kind network: ${kind_cidr} — patching MetalLB pools..."

  sed -i '' "s|[0-9]\+\.[0-9]\+\.[0-9]\+\.200-[0-9]\+\.[0-9]\+\.[0-9]\+\.210|${pool1}|" \
    "${REPO_ROOT}/argocd/overlays/kind-cluster1/metallb/ipaddresspool.yaml"
  sed -i '' "s|[0-9]\+\.[0-9]\+\.[0-9]\+\.220-[0-9]\+\.[0-9]\+\.[0-9]\+\.230|${pool2}|" \
    "${REPO_ROOT}/argocd/overlays/kind-cluster2/metallb/ipaddresspool.yaml"

  ok "MetalLB pools set — cluster1: ${pool1}  cluster2: ${pool2}"
}

# =============================================================================
# Istio remote secret exchange
# Gives each cluster's istiod a kubeconfig for the other so it can watch
# remote endpoints and drive cross-cluster load balancing. Must run after
# ArgoCD has deployed Istio on both clusters.
# =============================================================================
exchange_istio_secrets() {
  log "Waiting for istiod on cluster1..."
  kubectl --context="${CTX1}" wait \
    --for=condition=available deployment/istiod \
    -n istio-system --timeout=600s

  log "Waiting for istiod on cluster2..."
  kubectl --context="${CTX2}" wait \
    --for=condition=available deployment/istiod \
    -n istio-system --timeout=600s

  log "Exchanging Istio remote secrets..."

  istioctl create-remote-secret \
    --context="${CTX1}" \
    --name="${CLUSTER1}" \
    | kubectl apply -f - --context="${CTX2}"

  istioctl create-remote-secret \
    --context="${CTX2}" \
    --name="${CLUSTER2}" \
    | kubectl apply -f - --context="${CTX1}"

  ok "Remote secrets exchanged — cross-cluster service discovery active"
}

# =============================================================================
# Main
# =============================================================================
main() {
  local exchange_secrets=false
  [[ "${1:-}" == "--exchange-secrets" ]] && exchange_secrets=true

  check_prereqs
  create_clusters
  patch_metallb_ranges

  install_cilium "${CTX1}" "${CLUSTER1}"
  install_cilium "${CTX2}" "${CLUSTER2}"

  log "Waiting for all nodes to be Ready..."
  kubectl --context="${CTX1}" wait --for=condition=ready node --all --timeout=300s
  kubectl --context="${CTX2}" wait --for=condition=ready node --all --timeout=300s
  ok "All nodes Ready"

  install_argocd "${CTX1}" "argocd/overlays/kind-cluster1/argocd"
  install_argocd "${CTX2}" "argocd/overlays/kind-cluster2/argocd"

  if "${exchange_secrets}"; then
    exchange_istio_secrets
  fi

  echo ""
  echo "============================================================"
  if "${exchange_secrets}"; then
    echo " Setup complete — both clusters are in the mesh."
  else
    echo " ArgoCD is running on both clusters."
    echo " ApplicationSets are deploying: gateway-api-crds, metallb,"
    echo " cilium, istio, istio-eastwest. This takes a few minutes."
  fi
  echo ""
  echo " Watch cluster1:  kubectl --context=${CTX1} get applications -n argocd"
  echo " Watch cluster2:  kubectl --context=${CTX2} get applications -n argocd"
  echo ""
  if ! "${exchange_secrets}"; then
    echo " Once Istio is healthy on both clusters, complete the mesh:"
    echo "   ${SCRIPT_DIR}/bootstrap.sh --exchange-secrets"
    echo ""
  fi
  echo " Verify mesh:     istioctl remote-clusters --context=${CTX1}"
  echo " Simulate failure: docker stop ${CLUSTER1}-worker"
  echo "============================================================"
}

main "$@"
