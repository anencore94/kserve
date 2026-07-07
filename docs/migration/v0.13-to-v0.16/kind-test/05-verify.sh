#!/usr/bin/env bash
# Step 5 - the acceptance test. Proves the pre-existing InferenceService
# survived the upgrade AND exercises the #1 hazard in this version range:
# the RawDeployment->Standard / Serverless->Knative deploymentMode rename.
source "$(dirname "$0")/env.sh"
require kubectl
HERE="$(cd "$(dirname "$0")" && pwd)"
FAIL=0

log "=== 5.1 Is the pre-existing InferenceService still Ready? ==="
kubectl get isvc sklearn-iris -n "${SAMPLE_NS}" -o wide || true
if kubectl wait --for=condition=Ready --timeout=180s \
     inferenceservice/sklearn-iris -n "${SAMPLE_NS}"; then
  ok "existing ISVC is still Ready after upgrade"
else
  warn "existing ISVC is NOT Ready after upgrade"; FAIL=1
  kubectl describe isvc sklearn-iris -n "${SAMPLE_NS}" | tail -40
fi

log "=== 5.2 deploymentMode before vs after (the #4798 hazard) ==="
BEFORE="$(cat "${HERE}/artifacts/mode-before.txt" 2>/dev/null || echo '?')"
AFTER="$(kubectl get isvc sklearn-iris -n "${SAMPLE_NS}" -o jsonpath='{.status.deploymentMode}')"
echo "  status.deploymentMode BEFORE = '${BEFORE}'"
echo "  status.deploymentMode AFTER  = '${AFTER}'"
if [ "${AFTER}" = "Serverless" ] || [ "${AFTER}" = "RawDeployment" ]; then
  warn "status still carries the LEGACY mode string. Downstream '== Knative/Standard'"
  warn "checks compare against the NEW names, so this object may need a normalization"
  warn "pass (see 5.3). This is expected on v0.16.0."
fi

log "=== 5.3 Can we still MUTATE the existing object? (the freeze test) ==="
# Issue #4798: the v0.16 webhook can reject updates when the annotation and the
# status carry different mode vocabularies. Try a no-op label patch.
if kubectl patch isvc sklearn-iris -n "${SAMPLE_NS}" --type merge \
     -p '{"metadata":{"labels":{"upgrade-drill/mutation-test":"ok"}}}' 2>"${HERE}/artifacts/patch-err.txt"; then
  ok "existing object accepts updates (not frozen)"
else
  warn "UPDATE REJECTED - this is the #4798 freeze. Error:"
  cat "${HERE}/artifacts/patch-err.txt"
  warn "Remediation: normalize the mode, e.g.:"
  echo "  kubectl annotate isvc sklearn-iris -n ${SAMPLE_NS} \\"
  echo "    serving.kserve.io/deploymentMode=Standard --overwrite   # or Knative"
  FAIL=1
fi

log "=== 5.4 Live prediction through the predictor (port-forward) ==="
# Works for RawDeployment/Standard without an ingress controller.
SVC="$(kubectl get svc -n "${SAMPLE_NS}" -l serving.kserve.io/inferenceservice=sklearn-iris \
       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${SVC}" ]; then
  kubectl -n "${SAMPLE_NS}" port-forward "svc/${SVC}" 18080:80 >/tmp/pf.log 2>&1 &
  PF=$!; sleep 5
  cat > /tmp/iris-input.json <<'EOF'
{"instances": [[6.8, 2.8, 4.8, 1.4], [6.0, 3.4, 4.5, 1.6]]}
EOF
  if curl -sf -H 'Content-Type: application/json' \
       -d @/tmp/iris-input.json \
       "http://localhost:18080/v1/models/sklearn-iris:predict" | tee "${HERE}/artifacts/prediction.json"; then
    echo; ok "prediction succeeded on ${KSERVE_NEW}"
  else
    warn "prediction call failed (check runtime image compatibility for ${KSERVE_NEW})"; FAIL=1
  fi
  kill "${PF}" 2>/dev/null || true
else
  warn "predictor Service not found; skipping live prediction"
fi

log "=== 5.5 New v0.16 CRDs present? ==="
for c in llminferenceservices.serving.kserve.io localmodelcaches.serving.kserve.io; do
  if kubectl get crd "$c" >/dev/null 2>&1; then ok "new CRD present: $c";
  else warn "expected new CRD missing: $c"; fi
done

echo
if [ "${FAIL}" -eq 0 ]; then ok "=== VERIFY PASSED ==="; else warn "=== VERIFY FOUND ISSUES (see above) ==="; fi
exit "${FAIL}"
