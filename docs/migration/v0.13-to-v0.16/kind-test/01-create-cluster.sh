#!/usr/bin/env bash
# Step 1 - create a kind cluster and install the shared dependencies that both
# KServe versions need (cert-manager + Gateway API CRDs).
source "$(dirname "$0")/env.sh"
require docker kind kubectl helm

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "kind cluster '${CLUSTER_NAME}' already exists - reusing it"
else
  log "Creating kind cluster '${CLUSTER_NAME}'"
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
ok "kind cluster ready"

log "Installing cert-manager ${CERT_MANAGER_VERSION} (required by the KServe webhook)"
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true --wait
ok "cert-manager ready"

log "Installing Gateway API CRDs ${GATEWAY_API_VERSION} (standard channel)"
# v0.16 can use Gateway API. Installing the CRDs now keeps the upgrade step
# from failing even if you flip enableGatewayApi on later. Harmless for v0.13.
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
ok "dependencies installed"
