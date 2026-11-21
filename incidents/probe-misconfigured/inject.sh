#!/usr/bin/env bash
set -euo pipefail

NS="${TARGET_NAMESPACE:-go-api}"
DEPLOY="${TARGET_WORKLOAD:-go-api}"
FAULT="probe-misconfigured"
# The path a refactor renamed the probe to. The app still serves /ready, so
# every probe answers 404.
FAULT_PATH="/healthz"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/../_lib" && pwd)"
# shellcheck source=incidents/_lib/state.sh
. "$LIB/state.sh"
# shellcheck source=incidents/_lib/render.sh
. "$LIB/render.sh"

probe_get() {
  kubectl -n "$NS" get deploy "$DEPLOY" \
    -o "jsonpath={.spec.template.spec.containers[0].readinessProbe$1}" 2>/dev/null || true
}

# Guard on the fault itself, not on its record.
PATH_NOW="$(probe_get .httpGet.path)"
if [ "$PATH_NOW" = "$FAULT_PATH" ]; then
  echo "Fault already injected - nothing to do."
  exit 0
fi

PROBE="$(probe_get "")"
if [ -n "$(kubectl get nodes -o name 2>/dev/null || true)" ] && [ -z "$PATH_NOW" ]; then
  echo "ERROR: $NS/$DEPLOY has no HTTP readiness probe to change." >&2
  echo "  This fault needs one. Check with: kubectl -n $NS get deploy $DEPLOY -o yaml | grep -A 6 readinessProbe" >&2
  exit 1
fi

# Arm the paging rule first so the on-call drill measures real detection.
# Tolerate a missing prometheus operator: the fault still works unpaged.
MON_NS="${MONITORING_NAMESPACE:-monitoring}"
render_rule "$SCRIPT_DIR/alerts/rule.yaml" | kubectl apply -n "$MON_NS" -f - >/dev/null 2>&1 ||
  echo "Note: alert rule not installed (monitoring stack missing?) - continuing without paging."

# The whole probe is kept, so resolve can put it back even if it was deleted.
fault_state_save "$FAULT" "original-path=${PATH_NOW:-/ready}" "original-probe=${PROBE:-}"

# Nothing printed here names the fault: the brief is fault.yaml's description
# and the page this armed.
echo "Rolling out a config change to $NS/$DEPLOY..."
kubectl -n "$NS" patch deploy "$DEPLOY" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/httpGet/path\",\"value\":\"$FAULT_PATH\"}]" >/dev/null

# Retire the previous ReplicaSets so no old pod is left serving. With one
# replica, the default rolling update otherwise keeps the old pod up
# indefinitely next to a new one that never becomes ready: a stalled rollout,
# not the outage this fault is meant to be. The ReplicaSets stay, so
# `kubectl rollout undo` still works.
GEN="$(kubectl -n "$NS" get deploy "$DEPLOY" -o 'jsonpath={.metadata.generation}')"
i=0
while [ "$(kubectl -n "$NS" get deploy "$DEPLOY" -o 'jsonpath={.status.observedGeneration}')" != "$GEN" ] && [ "$i" -lt 30 ]; do
  i=$((i + 1))
  sleep 1
done
REV="$(kubectl -n "$NS" get deploy "$DEPLOY" -o 'jsonpath={.metadata.annotations.deployment\.kubernetes\.io/revision}')"
kubectl -n "$NS" get rs \
  -o 'jsonpath={range .items[*]}{.metadata.name} {.metadata.ownerReferences[0].name} {.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}{end}' |
  while read -r rs owner rev; do
    [ "$owner" = "$DEPLOY" ] && [ "$rev" != "$REV" ] || continue
    kubectl -n "$NS" scale rs "$rs" --replicas=0 >/dev/null
  done

# Return once no replica is marked ready, so the first status check sees the
# fault. FAULT_WAIT_SECONDS=0 skips the wait.
WAIT_SECONDS="${FAULT_WAIT_SECONDS:-60}"
waited=0
while [ "$waited" -lt "$WAIT_SECONDS" ]; do
  READY="$(kubectl -n "$NS" get deploy "$DEPLOY" -o 'jsonpath={.status.readyReplicas}' 2>/dev/null || true)"
  [ -n "$READY" ] && [ "$READY" -gt 0 ] || break
  sleep 5
  waited=$((waited + 5))
done
echo "Done."
