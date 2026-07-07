#!/usr/bin/env bash
# Step 0 - verify the local toolchain. Nothing here talks to a cluster.
source "$(dirname "$0")/env.sh"

require docker kind kubectl helm
ok "docker/kind/kubectl/helm are on PATH"

log "Tool versions:"
docker --version
kind version
kubectl version --client 2>/dev/null | head -1
helm version --short

log "Drill parameters:"
cat <<EOF
  OLD KServe version : ${KSERVE_OLD}
  NEW KServe version : ${KSERVE_NEW}
  cert-manager       : ${CERT_MANAGER_VERSION}
  gateway-api CRDs   : ${GATEWAY_API_VERSION}
  kind cluster       : ${CLUSTER_NAME}
  deployment mode    : ${DEPLOYMENT_MODE}
EOF

warn "This drill pulls images from ghcr.io, quay.io, docker.io and registry.k8s.io."
warn "Run it where those registries are reachable (a sandbox that blocks them will fail at image pull)."
ok "prerequisites look good"
