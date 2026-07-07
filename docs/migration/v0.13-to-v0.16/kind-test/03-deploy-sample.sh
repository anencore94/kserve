#!/usr/bin/env bash
# Step 3 - deploy a sample InferenceService on the OLD version and capture its
# "before" state (readiness + the deploymentMode the old controller recorded).
source "$(dirname "$0")/env.sh"
require kubectl
HERE="$(cd "$(dirname "$0")" && pwd)"

kubectl create namespace "${SAMPLE_NS}" --dry-run=client -o yaml | kubectl apply -f -

# Align the sample's requested mode with the mode the cluster runs in.
MODE_ANNOT="RawDeployment"
[ "${DEPLOYMENT_MODE}" = "Serverless" ] && MODE_ANNOT="Serverless"
log "Deploying sample InferenceService (requested mode annotation=${MODE_ANNOT})"
sed "s/serving.kserve.io\/deploymentMode: .*/serving.kserve.io\/deploymentMode: \"${MODE_ANNOT}\"/" \
  "${HERE}/../samples/sklearn-iris.yaml" | kubectl apply -n "${SAMPLE_NS}" -f -

log "Waiting for InferenceService to become Ready (up to 5m)"
if ! kubectl wait --for=condition=Ready --timeout=300s \
     inferenceservice/sklearn-iris -n "${SAMPLE_NS}"; then
  warn "ISVC not Ready yet - dumping state for debugging"
  kubectl get isvc,deploy,pod -n "${SAMPLE_NS}"
  kubectl describe isvc sklearn-iris -n "${SAMPLE_NS}" | tail -30
  exit 1
fi
ok "sample InferenceService is Ready on ${KSERVE_OLD}"

mkdir -p "${HERE}/artifacts"
BEFORE="${HERE}/artifacts/isvc-before.yaml"
kubectl get isvc sklearn-iris -n "${SAMPLE_NS}" -o yaml > "${BEFORE}"
log "Recorded status.deploymentMode BEFORE upgrade:"
kubectl get isvc sklearn-iris -n "${SAMPLE_NS}" \
  -o jsonpath='{.status.deploymentMode}{"\n"}' | tee "${HERE}/artifacts/mode-before.txt"
ok "before-state saved to ${BEFORE}"
