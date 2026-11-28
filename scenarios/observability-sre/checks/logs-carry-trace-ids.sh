#!/usr/bin/env bash
# Passes when the workload's logs are queryable in Loki by the labels the
# dashboards filter on (namespace and app) AND carry the trace_id that links a
# log line to its span.
#
# That link is what makes the three signals one story rather than three
# dashboards. It is also the step that silently does not work: logs ship fine
# without tracing configured, and every line is then a dead end.
set -euo pipefail
. "$(dirname "$0")/../../_lib/workload.sh"

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_grafana.sh"

NS="${WORKLOAD_NAMESPACE}"
FROM="$(window_start)000000000"
TO="$(window_end)000000000"
SELECTOR="{namespace=\"${NS}\", app=\"${WORKLOAD_NAME}\"}"

# loki_query <logql> <limit> prints Loki's query_range response, or nothing.
loki_query() {
  ds_get loki "/loki/api/v1/query_range" \
    --get --data-urlencode "query=$1" \
    --data-urlencode "limit=$2" \
    --data-urlencode "start=${FROM}" --data-urlencode "end=${TO}" 2>/dev/null || true
}

RESULT="$(loki_query "${SELECTOR} |= \`trace_id\`" 5)"

if [ -z "$RESULT" ] || ! printf '%s' "$RESULT" | grep -q '"status":"success"'; then
  echo "FAIL: Grafana's Loki datasource returned no successful response." >&2
  echo "  Is Alloy shipping? kubectl -n ${MONITORING_NAMESPACE} get ds alloy-logs" >&2
  echo "  Is Loki up?        kubectl -n ${MONITORING_NAMESPACE} get sts loki" >&2
  exit 1
fi

if printf '%s' "$RESULT" | grep -q 'trace_id'; then
  echo "OK: ${WORKLOAD_NAME} log lines from the last $((LOOKBACK_SECONDS / 60)) minutes are queryable in Loki and carry a trace_id."
  exit 0
fi

# Distinguish "no logs at all", "logs without the app label" and "logs without
# trace ids" - they have completely different causes and the learner should
# not have to guess which.
ANY_APP="$(loki_query "${SELECTOR}" 1)"
if printf '%s' "$ANY_APP" | grep -q '"values"'; then
  echo "FAIL: ${WORKLOAD_NAME} logs reach Loki, but no line carries a trace_id." >&2
  echo "  The app only stamps a trace_id once it is exporting spans, so wire it" >&2
  echo "  to the collector and send some traffic:" >&2
  echo "    kubectl -n ${NS} set env deployment/${WORKLOAD_NAME} \\" >&2
  echo "      OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy.${MONITORING_NAMESPACE}.svc.cluster.local:4318" >&2
  echo "    labctl traffic start --app ${WORKLOAD_NAME} --profile steady --rps 25" >&2
  exit 1
fi

ANY_NS="$(loki_query "{namespace=\"${NS}\"}" 1)"
if printf '%s' "$ANY_NS" | grep -q '"values"'; then
  echo "FAIL: logs from namespace ${NS} reach Loki, but none carry app=\"${WORKLOAD_NAME}\"." >&2
  echo "  Alloy copies the pod's app label onto each line, and the dashboards filter" >&2
  echo "  on it. Check the pod has it and that alloy-logs runs the platform's values:" >&2
  echo "    kubectl -n ${NS} get pods --show-labels" >&2
  echo "    kubectl -n ${MONITORING_NAMESPACE} get configmap alloy-logs -o yaml | grep -A2 pod_label_app" >&2
  exit 1
fi

echo "FAIL: no logs from namespace ${NS} are reaching Loki at all." >&2
echo "  Alloy reads the log files on each node; confirm it is running on the node" >&2
echo "  that holds the pod: kubectl -n ${MONITORING_NAMESPACE} get pods -l app.kubernetes.io/instance=alloy-logs -o wide" >&2
exit 1
