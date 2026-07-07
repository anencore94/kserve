#!/usr/bin/env bash
# Shared configuration for the KServe v0.13 -> v0.16 kind upgrade drill.
# Source this from every step script:  source "$(dirname "$0")/env.sh"
set -euo pipefail

# ----- versions under test -------------------------------------------------
export KSERVE_OLD="${KSERVE_OLD:-v0.13.0}"     # currently-running production version
export KSERVE_NEW="${KSERVE_NEW:-v0.16.0}"     # target (latest v0.16 line)

# Dependency versions (mirrors kserve-deps.env in the repo root).
export CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.0}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.1}"

# ----- cluster / namespace -------------------------------------------------
export CLUSTER_NAME="${CLUSTER_NAME:-kserve-upgrade}"
export KSERVE_NAMESPACE="${KSERVE_NAMESPACE:-kserve}"
export SAMPLE_NS="${SAMPLE_NS:-kserve-test}"

# Deployment mode used for this drill. "RawDeployment" (a.k.a. "Standard" in
# v0.16) keeps the cluster light: no Knative / Istio required, so it fits a
# laptop kind cluster. Switch to "Serverless" only if you also install Knative.
export DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-RawDeployment}"

# KServe publishes Helm charts to GHCR as OCI artifacts. The CRD chart name is
# stable across versions; the resources chart was renamed over time, so we
# resolve it per version in helpers below.
export KSERVE_CRD_CHART="oci://ghcr.io/kserve/charts/kserve-crd"

# The resources chart is published under "kserve" in recent releases; some
# older lines used "kserve-resources". resolve_kserve_chart <version> prints
# the OCI ref that actually exists for that version.
resolve_kserve_chart() {
  local ver="$1"
  for name in kserve kserve-resources; do
    if helm show chart "oci://ghcr.io/kserve/charts/${name}" --version "${ver}" >/dev/null 2>&1; then
      echo "oci://ghcr.io/kserve/charts/${name}"
      return 0
    fi
  done
  # Fallback: assume the modern name and let the caller surface the error.
  echo "oci://ghcr.io/kserve/charts/kserve"
}

# ----- install method: helm (default) or in-repo manifests -----------------
# INSTALL_METHOD=manifest forces the kubectl/manifest path (uses the version-
# pinned YAML already committed under install/ in this repo), which removes the
# dependency on GHCR Helm-chart availability for older versions like v0.13.
# When left as "helm", step 02 auto-falls-back to manifests if the OLD version's
# OCI chart cannot be resolved.
export INSTALL_METHOD="${INSTALL_METHOD:-helm}"

# Repo root (…/kserve) discovered from this file's location.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export REPO_ROOT

# Map a KServe version to the install/ directory that ships its manifests.
# This repo carries v0.13 only as the rc0 cut; map v0.13.0 onto it.
kserve_manifest_dir() {
  local ver="$1" d
  for d in "install/${ver}" "install/${ver}-rc1" "install/${ver}-rc0"; do
    [ -d "${REPO_ROOT}/${d}" ] && { echo "${REPO_ROOT}/${d}"; return 0; }
  done
  return 1
}

# True if the OCI resources chart for this version can be resolved via Helm.
kserve_oci_chart_available() {
  local ver="$1" name
  for name in kserve kserve-resources; do
    helm show chart "oci://ghcr.io/kserve/charts/${name}" --version "${ver}" >/dev/null 2>&1 && return 0
  done
  return 1
}

# Install (or upgrade) KServe from the in-repo manifests for <version>.
# CRDs live inside kserve.yaml; --server-side is mandatory (the ISVC CRD is too
# large for client-side apply). cluster-resources.yaml is applied after so its
# ClusterServingRuntimes/ClusterStorageContainers find their CRDs.
install_kserve_from_manifest() {
  local ver="$1" dir
  dir="$(kserve_manifest_dir "${ver}")" || {
    echo "no in-repo manifest dir for ${ver} under ${REPO_ROOT}/install/" >&2; return 1; }
  log "Applying in-repo manifests for ${ver} from ${dir}"
  kubectl apply --server-side --force-conflicts -f "${dir}/kserve.yaml"
  [ -f "${dir}/kserve-cluster-resources.yaml" ] && \
    kubectl apply --server-side --force-conflicts -f "${dir}/kserve-cluster-resources.yaml"
}

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }

require() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "missing required tool: $c" >&2; exit 1; }
  done
}
