#!/usr/bin/env bash
# Step 2 - install the *current* production version (KSERVE_OLD) via Helm,
# CRD chart first, then the resources chart. This reproduces the "before" state.
source "$(dirname "$0")/env.sh"
require kubectl helm

# Decide helm vs manifest. Older versions (v0.13) may not be published as OCI
# charts; in that case fall back to the version-pinned manifests in this repo.
USE_MANIFEST=false
if [ "${INSTALL_METHOD}" = "manifest" ]; then
  USE_MANIFEST=true
  log "INSTALL_METHOD=manifest -> using in-repo manifests"
elif ! kserve_oci_chart_available "${KSERVE_OLD}"; then
  warn "No OCI Helm chart resolvable for ${KSERVE_OLD}; falling back to in-repo manifests"
  USE_MANIFEST=true
fi

kubectl create namespace "${KSERVE_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

if [ "${USE_MANIFEST}" = true ]; then
  install_kserve_from_manifest "${KSERVE_OLD}"
else
  CHART="$(resolve_kserve_chart "${KSERVE_OLD}")"
  log "Resolved ${KSERVE_OLD} resources chart -> ${CHART}"

  log "Installing KServe CRDs ${KSERVE_OLD}"
  helm upgrade --install kserve-crd "${KSERVE_CRD_CHART}" \
    --version "${KSERVE_OLD}" \
    --namespace "${KSERVE_NAMESPACE}" --create-namespace --wait

  log "Installing KServe controller ${KSERVE_OLD} (mode=${DEPLOYMENT_MODE})"
  helm upgrade --install kserve "${CHART}" \
    --version "${KSERVE_OLD}" \
    --namespace "${KSERVE_NAMESPACE}" --create-namespace --wait \
    --set-string kserve.controller.deploymentMode="${DEPLOYMENT_MODE}" || {
      warn "install --wait returned non-zero; controller may need a moment - continuing to verify"
    }
fi

# Make sure the default deployment mode is what we expect regardless of chart
# value plumbing differences between versions.
kubectl patch configmap inferenceservice-config -n "${KSERVE_NAMESPACE}" --type merge \
  -p "{\"data\":{\"deploy\":\"{\\\"defaultDeploymentMode\\\":\\\"${DEPLOYMENT_MODE}\\\"}\"}}" || true
kubectl rollout restart deployment kserve-controller-manager -n "${KSERVE_NAMESPACE}"

kubectl rollout status deployment kserve-controller-manager -n "${KSERVE_NAMESPACE}" --timeout=300s
ok "KServe ${KSERVE_OLD} controller is ready"

log "Installed CRDs:"
kubectl get crd | grep -E 'serving.kserve.io|networking.x-k8s.io' || true
