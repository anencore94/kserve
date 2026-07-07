#!/usr/bin/env bash
# Step 4 - the online upgrade itself: CRDs first, then the controller, using
# `helm upgrade`. Existing InferenceServices keep running throughout.
source "$(dirname "$0")/env.sh"
require kubectl helm
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "${HERE}/artifacts"

log "### SAFETY NET: backing up every serving.kserve.io CR + config BEFORE touching anything"
kubectl get isvc,servingruntime,clusterservingruntime,inferencegraph,trainedmodel \
  -A -o yaml > "${HERE}/artifacts/all-crs-backup.yaml" 2>/dev/null || true
kubectl get configmap inferenceservice-config -n "${KSERVE_NAMESPACE}" -o yaml \
  > "${HERE}/artifacts/inferenceservice-config-backup.yaml" 2>/dev/null || true
# Record the currently-installed CRD schema so a rollback can restore it.
for crd in inferenceservices servingruntimes clusterservingruntimes inferencegraphs \
           trainedmodels clusterstoragecontainers; do
  kubectl get crd "${crd}.serving.kserve.io" -o yaml \
    > "${HERE}/artifacts/crd-${crd}-old.yaml" 2>/dev/null || true
done
ok "backups written to ${HERE}/artifacts/"

# Mirror step 02's method choice so the drill is consistent end to end.
USE_MANIFEST=false
if [ "${INSTALL_METHOD}" = "manifest" ]; then
  USE_MANIFEST=true
elif ! kserve_oci_chart_available "${KSERVE_NEW}"; then
  warn "No OCI Helm chart resolvable for ${KSERVE_NEW}; falling back to in-repo manifests"
  USE_MANIFEST=true
fi

# v0.16 renamed RawDeployment->Standard and Serverless->Knative. Map the mode.
NEW_MODE="${DEPLOYMENT_MODE}"
[ "${DEPLOYMENT_MODE}" = "RawDeployment" ] && NEW_MODE="Standard"
[ "${DEPLOYMENT_MODE}" = "Serverless" ]    && NEW_MODE="Knative"
log "Deployment mode ${DEPLOYMENT_MODE} -> ${NEW_MODE} (v0.16 vocabulary)"

# The golden rule holds for BOTH methods: CRDs are applied before/with the
# controller, and we NEVER delete the CRDs (that would GC every ISVC).
if [ "${USE_MANIFEST}" = true ]; then
  # kserve.yaml carries CRDs + controller; --server-side applies them in one
  # shot and CRDs are established before the controller needs them.
  install_kserve_from_manifest "${KSERVE_NEW}"
else
  NEW_CHART="$(resolve_kserve_chart "${KSERVE_NEW}")"
  log "Resolved ${KSERVE_NEW} resources chart -> ${NEW_CHART}"

  # ---- 4a. CRDs FIRST -----------------------------------------------------
  log "Upgrading KServe CRDs -> ${KSERVE_NEW}"
  helm upgrade --install kserve-crd "${KSERVE_CRD_CHART}" \
    --version "${KSERVE_NEW}" \
    --namespace "${KSERVE_NAMESPACE}" --wait

  # ---- 4b. controller SECOND ----------------------------------------------
  log "Upgrading KServe controller -> ${KSERVE_NEW}"
  helm upgrade --install kserve "${NEW_CHART}" \
    --version "${KSERVE_NEW}" \
    --namespace "${KSERVE_NAMESPACE}" --wait || \
    warn "helm --wait returned non-zero; verifying controller rollout directly"
fi

# Re-assert deployment mode in the config so the new controller keeps steering
# existing workloads to the same runtime path.
kubectl patch configmap inferenceservice-config -n "${KSERVE_NAMESPACE}" --type merge \
  -p "{\"data\":{\"deploy\":\"{\\\"defaultDeploymentMode\\\":\\\"${NEW_MODE}\\\"}\"}}" || true
kubectl rollout restart deployment kserve-controller-manager -n "${KSERVE_NAMESPACE}"
kubectl rollout status deployment kserve-controller-manager -n "${KSERVE_NAMESPACE}" --timeout=300s
ok "KServe controller upgraded to ${KSERVE_NEW}"

log "CRDs after upgrade:"
kubectl get crd | grep -E 'serving.kserve.io|networking.x-k8s.io' || true
