#!/usr/bin/env bash
# Step 99 - delete the kind cluster and everything in it.
source "$(dirname "$0")/env.sh"
require kind
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "Deleting kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}"
  ok "cluster deleted"
else
  warn "no kind cluster named '${CLUSTER_NAME}'"
fi
