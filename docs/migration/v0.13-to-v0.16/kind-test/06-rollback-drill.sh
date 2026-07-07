#!/usr/bin/env bash
# Step 6 - rollback drill. Proves you can return the CONTROLLER to the old
# version without losing InferenceServices, and shows the one thing that does
# NOT roll back cleanly (mode strings normalized forward by the new controller).
#
# Golden rule tested here: roll back the CONTROLLER + CRD SCHEMA, never
# `helm uninstall` the CRD chart (that would GC-delete every CR).
source "$(dirname "$0")/env.sh"
require kubectl helm
HERE="$(cd "$(dirname "$0")" && pwd)"

log "=== 6.1 Roll the controller back to ${KSERVE_OLD} ==="
# If KServe was installed via Helm, use helm's own release history. If it was
# installed from manifests (no helm release), re-apply the OLD manifests -
# which downgrades the CONTROLLER image while leaving the (additive) CRDs in
# place. Either way the CRDs are never deleted.
if helm history kserve -n "${KSERVE_NAMESPACE}" >/dev/null 2>&1; then
  log "Helm release found -> rolling back via helm"
  OLD_CHART="$(resolve_kserve_chart "${KSERVE_OLD}")"
  helm rollback kserve 1 -n "${KSERVE_NAMESPACE}" --wait || \
    helm upgrade kserve "${OLD_CHART}" --version "${KSERVE_OLD}" \
      -n "${KSERVE_NAMESPACE}" --wait
else
  log "No Helm release -> re-applying ${KSERVE_OLD} manifests (controller downgrade)"
  install_kserve_from_manifest "${KSERVE_OLD}"
  kubectl rollout status deployment kserve-controller-manager -n "${KSERVE_NAMESPACE}" --timeout=300s || true
fi

log "=== 6.2 CRD schema: additive changes mean the OLD schema still validates OLD CRs ==="
# We deliberately do NOT downgrade the CRDs. Because v0.16 only ADDED CRDs and
# fields (InferenceService stayed v1beta1, no stored-version change, no
# conversion webhook), the newer CRDs happily keep serving your existing
# objects even with the old controller. Downgrading CRDs is optional and only
# needed if you must remove fields the old controller rejects (rare).
kubectl get crd inferenceservices.serving.kserve.io \
  -o jsonpath='{.spec.versions[*].name}{"\n"}'

log "=== 6.3 Restore config + normalize any forward-migrated mode strings ==="
if [ -f "${HERE}/artifacts/inferenceservice-config-backup.yaml" ]; then
  kubectl apply -f "${HERE}/artifacts/inferenceservice-config-backup.yaml" || true
fi
kubectl rollout restart deployment kserve-controller-manager -n "${KSERVE_NAMESPACE}" || true
kubectl rollout status deployment kserve-controller-manager -n "${KSERVE_NAMESPACE}" --timeout=300s || true

log "=== 6.4 Is the sample still Ready under the rolled-back controller? ==="
kubectl get isvc sklearn-iris -n "${SAMPLE_NS}" -o wide || true
kubectl wait --for=condition=Ready --timeout=180s \
  inferenceservice/sklearn-iris -n "${SAMPLE_NS}" && \
  ok "rollback succeeded: existing ISVC Ready on ${KSERVE_OLD} again" || \
  warn "sample not Ready after rollback - inspect status.deploymentMode; you may need
        to re-apply the backed-up CR from artifacts/all-crs-backup.yaml"

cat <<'EOF'

NOTE ON ROLLBACK LIMITS
-----------------------
* Rolling the CONTROLLER back is safe and fast; your CRs are never deleted.
* The one-way item: if the new controller already rewrote an object's
  status.deploymentMode into the new vocabulary (Standard/Knative), the old
  controller may not recognize it. Fix by re-applying the pre-upgrade CR from
  artifacts/all-crs-backup.yaml (it still has the old status) OR annotate the
  object back to the legacy value.
* NEVER `helm uninstall kserve-crd` as part of rollback - it garbage-collects
  every InferenceService/ServingRuntime in the cluster.
EOF
