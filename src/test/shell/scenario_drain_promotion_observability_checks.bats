#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# Grading scripts of node-drain-drill, env-promotion and observability-sre.
# Each is run against the lab before the work, the solved lab, the shortcuts
# that would turn it green without the work, and a cluster that cannot answer.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  export WORKLOAD_NAME=cart WORKLOAD_NAMESPACE=shop MONITORING_NAMESPACE=monitoring
  export GRAFANA_URL=http://grafana.lab.test
  stub_script kubectl <<'STUB'
if [ -n "${FAIL_ON:-}" ]; then
  case "$*" in *"$FAIL_ON"*) exit 1 ;; esac
fi
case "$*" in
  # node-drain-drill
  "get nodes"*) [ -z "${CORDONED-}" ] || printf '%s\n' "$CORDONED" ;;
  *"get configmap cart-drain-drill-baseline"*) printf '%s' "${BEFORE-node-1 node-2}" ;;
  *"get pods -l app=cart"*) [ -z "${NOW-set}" ] || printf '%s\n' ${NOW-node-1 node-2} ;;
  *"get pdb"*) [ -z "${PDBS-set}" ] || printf '%s\n' "${PDBS-cart-drill-pdb cart node-drain-drill}" ;;

  # env-promotion
  *"-n env-prod get deploy cart"*) [ "${PROD_DEPLOYED:-yes}" = yes ] || exit 1 ;;
  *"-n env-prod get rs"*"revision"*)
    [ "${RS_READABLE:-yes}" = yes ] || exit 1
    [ -z "${RS_LIST-}" ] || printf '%s\n' "$RS_LIST"
    ;;

  # observability-sre
  *"get secret grafana"*) printf 'YWRtaW4=' ;;
esac
exit 0
STUB
  # Grafana's datasource proxy: Tempo's tag values, and Loki answering the
  # trace_id query, the app's any-line query and the namespace's separately.
  # The app's answer defaults to the namespace's.
  stub_script curl <<'STUB'
case "$*" in
  *"/uid/tempo/"*) printf '%s' "${TEMPO-}" ;;
  *"/uid/loki/"*)
    case "$*" in
      *trace_id*) printf '%s' "${LOKI_TRACED-}" ;;
      *'app="cart"'*) printf '%s' "${LOKI_APP-${LOKI_ANY-}}" ;;
      *) printf '%s' "${LOKI_ANY-}" ;;
    esac
    ;;
esac
STUB
}

teardown() {
  stub_teardown
}

check() {
  run bash "$ROOT/scenarios/$1"
}

# ── node-drain-drill: no node left cordoned ───────────────────────────────────

@test "no-cordon passes when every node is schedulable" {
  check node-drain-drill/checks/check-no-cordon.sh
  [ "$status" -eq 0 ]
}

@test "no-cordon fails while a drained node is still cordoned, naming it" {
  CORDONED=node-2 check node-drain-drill/checks/check-no-cordon.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"node-2"* ]] || false
  [[ "$output" == *"kubectl uncordon"* ]] || false
}

@test "no-cordon does not pass a cluster it could not query" {
  FAIL_ON="get nodes" check node-drain-drill/checks/check-no-cordon.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list the nodes"* ]] || false
}

# ── node-drain-drill: pods were evicted ───────────────────────────────────────

@test "pods-evicted fails before any drain: every node still holds the pods" {
  check node-drain-drill/checks/check-pods-evicted.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no drain has moved a pod"* ]] || false
}

@test "pods-evicted passes once a node that held the pods holds none" {
  NOW="node-2 node-3" check node-drain-drill/checks/check-pods-evicted.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"node-1 held cart pods before the drain and holds none now"* ]] || false
}

@test "pods-evicted fails the wrong fix: the workload scaled to zero" {
  NOW="" check node-drain-drill/checks/check-pods-evicted.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no cart pod is running in shop"* ]] || false
}

@test "pods-evicted fails a drain of a node that held none of the pods" {
  BEFORE="node-1" NOW="node-1" check node-drain-drill/checks/check-pods-evicted.sh
  [ "$status" -ne 0 ]
}

@test "pods-evicted cannot grade without the placement recorded at activation" {
  BEFORE="" check node-drain-drill/checks/check-pods-evicted.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pre-drain placement was recorded"* ]] || false
}

# ── node-drain-drill: one budget per workload ─────────────────────────────────

@test "single-pdb passes with the drill's own budget, or none" {
  check node-drain-drill/checks/check-single-pdb.sh
  [ "$status" -eq 0 ]
  PDBS="" check node-drain-drill/checks/check-single-pdb.sh
  [ "$status" -eq 0 ]
}

@test "single-pdb ignores budgets that select another app" {
  PDBS="$(printf 'cart-drill-pdb cart node-drain-drill\nother-pdb other autoscaling')" \
    check node-drain-drill/checks/check-single-pdb.sh
  [ "$status" -eq 0 ]
}

@test "single-pdb fails two budgets on the same pods and says where each came from" {
  PDBS="$(printf 'cart-drill-pdb cart node-drain-drill\ncart-pdb cart autoscaling-under-load')" \
    check node-drain-drill/checks/check-single-pdb.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 PodDisruptionBudgets select cart"* ]] || false
  [[ "$output" == *"cart-pdb (from: autoscaling-under-load)"* ]] || false
}

@test "single-pdb does not pass a cluster it could not query" {
  FAIL_ON="get pdb" check node-drain-drill/checks/check-single-pdb.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list the PodDisruptionBudgets"* ]] || false
}

# ── env-promotion: a rollback was exercised ───────────────────────────────────

@test "rollback-was-exercised is pending while prod has had one ReplicaSet" {
  RS_LIST="1 cart-aaa " check env-promotion/checks/rollback-was-exercised.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"only had one ReplicaSet"* ]] || false
}

@test "rollback-was-exercised is pending while prod has only rolled forward" {
  RS_LIST="$(printf '1 cart-aaa \n2 cart-bbb ')" check env-promotion/checks/rollback-was-exercised.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"only ever rolled forward"* ]] || false
}

@test "rollback-was-exercised passes when prod serves an older ReplicaSet again" {
  RS_LIST="$(printf '3 cart-aaa 1\n2 cart-bbb ')" check env-promotion/checks/rollback-was-exercised.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"serving cart-aaa (revision 3), which it served before as"* ]] || false
}

@test "rollback-was-exercised compares revisions as numbers" {
  RS_LIST="$(printf '10 cart-aaa 8\n9 cart-bbb ')" check env-promotion/checks/rollback-was-exercised.sh
  [ "$status" -eq 0 ]
}

@test "rollback-was-exercised does not count a rollback that prod has since rolled forward from" {
  RS_LIST="$(printf '3 cart-aaa 1\n2 cart-bbb \n4 cart-ccc ')" check env-promotion/checks/rollback-was-exercised.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"serving its newest ReplicaSet (cart-ccc)"* ]] || false
}

@test "rollback-was-exercised fails when prod has no Deployment" {
  PROD_DEPLOYED=no check env-promotion/checks/rollback-was-exercised.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no cart Deployment in env-prod"* ]] || false
}

@test "rollback-was-exercised fails when the ReplicaSets cannot be read" {
  RS_READABLE=no check env-promotion/checks/rollback-was-exercised.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read the ReplicaSets"* ]] || false
}

# ── observability-sre: traces in Tempo ────────────────────────────────────────

@test "traces-in-tempo fails before the app exports spans, listing what Tempo has" {
  TEMPO='{"tagValues":["traefik","alloy"]}' check observability-sre/checks/traces-in-tempo.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no spans for service.name=cart"* ]] || false
  [[ "$output" == *"traefik"* ]] || false
}

@test "traces-in-tempo passes once Tempo holds the app's service name" {
  TEMPO='{"tagValues":["traefik","cart"]}' check observability-sre/checks/traces-in-tempo.sh
  [ "$status" -eq 0 ]
}

@test "traces-in-tempo is not satisfied by another service whose name contains the app's" {
  TEMPO='{"tagValues":["cart-worker","shopping-cart"]}' check observability-sre/checks/traces-in-tempo.sh
  [ "$status" -ne 0 ]
}

@test "traces-in-tempo fails with the datasource hint when Tempo answers nothing" {
  check observability-sre/checks/traces-in-tempo.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tempo datasource returned nothing"* ]] || false
}

@test "traces-in-tempo asks only about the recent window" {
  TEMPO='{"tagValues":["cart"]}' LOOKBACK_SECONDS=600 check observability-sre/checks/traces-in-tempo.sh
  url="$(calls_for curl | sed -n 's/.*\(start=[0-9]*&end=[0-9]*\).*/\1/p')"
  start="${url#start=}"
  start="${start%%&*}"
  end="${url##*end=}"
  [ "$((end - start))" -eq 600 ]
}

# ── observability-sre: logs carry trace ids ───────────────────────────────────

any_logs='{"status":"success","data":{"result":[{"values":[["1","GET /health 200"]]}]}}'
no_logs='{"status":"success","data":{"result":[]}}'

@test "logs-carry-trace-ids fails before the app exports spans: logs arrive without a trace id" {
  LOKI_TRACED="$no_logs" LOKI_ANY="$any_logs" check observability-sre/checks/logs-carry-trace-ids.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no line carries a trace_id"* ]] || false
  [[ "$output" == *"OTEL_EXPORTER_OTLP_ENDPOINT"* ]] || false
}

@test "logs-carry-trace-ids passes when a recent line carries a trace id" {
  LOKI_TRACED='{"status":"success","data":{"result":[{"values":[["1","{\"trace_id\":\"abc\"}"]]}]}}' \
    check observability-sre/checks/logs-carry-trace-ids.sh
  [ "$status" -eq 0 ]
}

@test "logs-carry-trace-ids fails when no logs from the namespace reach Loki" {
  LOKI_TRACED="$no_logs" LOKI_ANY="$no_logs" check observability-sre/checks/logs-carry-trace-ids.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no logs from namespace shop are reaching Loki"* ]] || false
}

# The dashboards filter on app. Lines that reach Loki without it leave every
# panel empty, so the check must not pass on the namespace alone.
@test "logs-carry-trace-ids fails when the namespace's logs carry no app label" {
  LOKI_TRACED="$no_logs" LOKI_APP="$no_logs" LOKI_ANY="$any_logs" check observability-sre/checks/logs-carry-trace-ids.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'none carry app="cart"'* ]] || false
  [[ "$output" == *"alloy-logs"* ]] || false
}

@test "logs-carry-trace-ids asks Loki for the app's lines, not the whole namespace" {
  LOKI_TRACED='{"status":"success","data":{"result":[{"values":[["1","{\"trace_id\":\"abc\"}"]]}]}}' \
    check observability-sre/checks/logs-carry-trace-ids.sh
  [ "$status" -eq 0 ]
  assert_called curl 'query={namespace="shop", app="cart"} |= `trace_id`'
}

@test "logs-carry-trace-ids fails when Loki cannot be queried" {
  check observability-sre/checks/logs-carry-trace-ids.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"returned no successful response"* ]] || false

  LOKI_TRACED='{"status":"error","message":"trace_id parse error"}' check observability-sre/checks/logs-carry-trace-ids.sh
  [ "$status" -ne 0 ]
}
