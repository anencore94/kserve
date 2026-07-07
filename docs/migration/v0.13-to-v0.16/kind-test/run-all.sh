#!/usr/bin/env bash
# Convenience wrapper: run the full drill end to end.
#   ./run-all.sh                 # RawDeployment (light, default)
#   DEPLOYMENT_MODE=Serverless ./run-all.sh   # requires Knative+Istio (heavier)
#   KSERVE_NEW=v0.18.0 ./run-all.sh           # target a different version
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for step in 00-prereqs 01-create-cluster 02-install-kserve-old \
            03-deploy-sample 04-upgrade 05-verify 06-rollback-drill; do
  echo; echo "############################################################"
  echo "# ${step}"
  echo "############################################################"
  bash "${HERE}/${step}.sh"
done
echo
echo "Drill complete. Artifacts in ${HERE}/artifacts/. Tear down with ./99-teardown.sh"
