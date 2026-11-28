#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# Install idempotency for the default-stack providers a reviewer's core loop
# always runs (ingress + monitoring). The install must use `helm upgrade
# --install` - the idempotent primitive - so a re-run after an interrupted
# `labctl init` converges instead of erroring (golden rule 5).

load 'helpers/stub'

setup() {
  stub_setup
  stub_command kubectl helm
  ROOT="$(project_root)"
}

teardown() {
  stub_teardown
}

@test "traefik install uses helm upgrade --install" {
  run bash "$ROOT/platform/ingress/traefik/install.sh"
  [ "$status" -eq 0 ]
  assert_called helm "upgrade --install"
}

@test "traefik install is safe to run twice (converges)" {
  run bash "$ROOT/platform/ingress/traefik/install.sh"
  [ "$status" -eq 0 ]
  reset_calls
  run bash "$ROOT/platform/ingress/traefik/install.sh"
  [ "$status" -eq 0 ]
  assert_called helm "upgrade --install"
}

@test "prometheus install uses helm upgrade --install" {
  run bash "$ROOT/platform/monitoring/metrics/prometheus/install.sh"
  [ "$status" -eq 0 ]
  assert_called helm "upgrade --install"
}

@test "prometheus install is safe to run twice (converges)" {
  run bash "$ROOT/platform/monitoring/metrics/prometheus/install.sh"
  [ "$status" -eq 0 ]
  reset_calls
  run bash "$ROOT/platform/monitoring/metrics/prometheus/install.sh"
  [ "$status" -eq 0 ]
  assert_called helm "upgrade --install"
}

@test "grafana install uses helm upgrade --install" {
  run bash "$ROOT/platform/monitoring/grafana/install.sh"
  [ "$status" -eq 0 ]
  assert_called helm "upgrade --install grafana"
}

# A helm process that dies mid-operation leaves the release pending, and every
# later upgrade fails with "another operation ... is in progress" until it is
# cleared.
@test "a release stuck in pending-install is uninstalled before installing" {
  stub_when helm "status grafana" 0 "STATUS: pending-install"
  run bash "$ROOT/platform/monitoring/grafana/install.sh"
  [ "$status" -eq 0 ]
  assert_called helm "uninstall grafana --namespace monitoring"
  refute_called helm "rollback"
  assert_called helm "upgrade --install grafana"
}

@test "a release stuck in pending-upgrade is rolled back before upgrading" {
  stub_when helm "status traefik" 0 "STATUS: pending-upgrade"
  run bash "$ROOT/platform/ingress/traefik/install.sh"
  [ "$status" -eq 0 ]
  assert_called helm "rollback traefik --namespace traefik"
  refute_called helm "uninstall"
  assert_called helm "upgrade --install traefik"
}

@test "a deployed release is upgraded without being cleared" {
  stub_when helm "status prometheus" 0 "STATUS: deployed"
  run bash "$ROOT/platform/monitoring/metrics/prometheus/install.sh"
  [ "$status" -eq 0 ]
  refute_called helm "uninstall"
  refute_called helm "rollback"
  assert_called helm "upgrade --install prometheus prometheus-community/kube-prometheus-stack"
}

@test "a failed clear stops the install" {
  stub_when helm "status grafana" 0 "STATUS: pending-install"
  stub_when helm "uninstall grafana" 1
  run bash "$ROOT/platform/monitoring/grafana/install.sh"
  [ "$status" -ne 0 ]
  refute_called helm "upgrade --install"
}

# kind has no LoadBalancer implementation, so helm --wait on a LoadBalancer
# Service never returns there.
@test "traefik on kind binds the ingress node's host ports, not a LoadBalancer" {
  PROFILE=kind run bash "$ROOT/platform/ingress/traefik/install.sh"
  [ "$status" -eq 0 ]
  assert_called helm "service.spec.type=ClusterIP"
  assert_called helm "ports.web.hostPort=80"
  assert_called helm "ports.websecure.hostPort=443"
  assert_called helm "nodeSelector.ingress-ready=true"
  assert_called helm "key=node-role.kubernetes.io/control-plane"
}

@test "traefik on k3d keeps the LoadBalancer from its values file" {
  PROFILE=k3d run bash "$ROOT/platform/ingress/traefik/install.sh"
  [ "$status" -eq 0 ]
  assert_called helm "upgrade --install traefik"
  refute_called helm "hostPort"
  refute_called helm "service.spec.type"
  grep -A2 '^service:' "$ROOT/platform/ingress/traefik/values.yaml" | grep -q 'type: LoadBalancer'
}

# A component's volume uses the runtime's StorageClass (STORAGE_CLASS, from
# runtimes/<profile>/runtime.env). A class named in a values file exists on one
# runtime only, so the claim never binds on the others.
@test "grafana, loki and tempo claim volumes from the runtime's storage class" {
  for c in "monitoring/grafana|persistence.storageClassName=standard" \
    "logging/loki|singleBinary.persistence.storageClass=standard" \
    "tracing/tempo|persistence.storageClassName=standard"; do
    reset_calls
    STORAGE_CLASS=standard run bash "$ROOT/platform/${c%%|*}/install.sh"
    [ "$status" -eq 0 ] || { echo "${c%%|*}: $output"; false; }
    assert_called helm "${c#*|}"
  done
}

@test "no platform values file names a storage class of one runtime" {
  run grep -rln "local-path" "$ROOT/platform" --include=values.yaml
  [ "$status" -ne 0 ] || { echo "hardcoded storage class in: $output"; false; }
}

# The external-secrets chart's ServiceMonitor template brings its own
# external-secrets-metrics Service; metrics.service makes a second one, and on
# a lab with Prometheus the install fails with "already exists".
@test "external-secrets turns on the ServiceMonitor without a second metrics Service" {
  values="$ROOT/platform/secrets/external-secrets/values.yaml"
  awk '/^serviceMonitor:/ { on = 1; next } on && /^[^ ]/ { exit } on && /enabled: true/ { found = 1 } END { exit !found }' "$values"
  run awk '/^metrics:/ { m = 1; next } m && /^[^ ]/ { m = 0 } m && /^  service:/ { s = 1; next } s && /^  [^ ]/ { s = 0 } s && /enabled: true/ { print; found = 1 } END { exit !found }' "$values"
  [ "$status" -ne 0 ] || { echo "metrics.service.enabled is true in ${values#"$ROOT"/}"; false; }
}

# The platform part is installed once, for whichever app is bound at the time,
# so anything in it that names an app is missing for every other app. The
# ExternalSecret belongs to the scenario; the platform brings one
# ClusterSecretStore whose token sits next to the operator.
@test "external-secrets install names no app" {
  export WORKLOAD_NAME=cart WORKLOAD_NAMESPACE=shop SECRETS_NAMESPACE=shop
  stub_script kubectl <<'EOF'
case "$*" in
  "apply -f -") cat >>"$STUB_DIR/applied.yaml" ;;
esac
EOF
  run bash "$ROOT/platform/secrets/external-secrets/install.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printed="$output"
  applied="$STUB_DIR/applied.yaml"

  run grep -c '^kind: ClusterSecretStore$' "$applied"
  [ "$output" = 1 ] || { cat "$applied"; false; }
  grep -q '^          namespace: external-secrets$' "$applied" || { cat "$applied"; false; }
  run grep -E '^kind: (ExternalSecret|SecretStore)$' "$applied"
  [ "$status" -ne 0 ] || { echo "applies an app's wiring: $output"; false; }
  assert_called kubectl "create secret generic vault-token --namespace external-secrets"
  run grep -E 'cart|shop|go-api' "$STUB_LOG" "$applied"
  [ "$status" -ne 0 ] || { echo "names an app: $output"; false; }
  case "$printed" in
    *cart* | *shop* | *go-api*) echo "prints an app: $printed" && false ;;
  esac
}

# Grafana lists a datasource only while its backend is installed. A Loki or
# Tempo datasource on a lab without logging or tracing fails its health check
# and reads as a broken lab, so grafana provisions Prometheus alone and loki
# and tempo bring their own datasource as a ConfigMap the sidecar loads.
@test "grafana provisions Prometheus alone and loads other datasources from ConfigMaps" {
  values="$ROOT/platform/monitoring/grafana/values.yaml"
  run grep -nE 'type: (loki|tempo)$' "$values"
  [ "$status" -ne 0 ] || { echo "grafana provisions: $output"; false; }
  grep -q 'type: prometheus$' "$values"
  run awk '/^sidecar:/ { s = 1; next } s && /^[^ ]/ { s = 0 } s && /^  datasources:/ { d = 1; next } d && /^  [^ ]/ { d = 0 } d { print }' "$values"
  [[ "$output" == *"enabled: true"* ]] || { echo "datasource sidecar is off: $output"; false; }
  [[ "$output" == *"label: grafana_datasource"* ]] || { echo "$output"; false; }
  [[ "$output" == *'labelValue: "1"'* ]] || { echo "$output"; false; }
  # GF_SECURITY_ADMIN_USER in env stops the chart from passing the user the
  # sidecar's reload call needs (it still passes the password).
  [[ "$output" == *"REQ_USERNAME:"* ]] || { echo "reload has no user: $output"; false; }
  [[ "$output" != *"REQ_PASSWORD:"* ]] || { echo "the chart already sets REQ_PASSWORD: $output"; false; }
}

# prune drops only what a prune: true file added, so grafana's own file deletes
# Loki and Tempo by name. Grafana reads the files in name order: every provider
# file must sort after grafana's, or its datasource is deleted after it is added.
@test "grafana deletes stale Loki and Tempo before the providers' files add them" {
  values="$ROOT/platform/monitoring/grafana/values.yaml"
  run awk '/^    deleteDatasources:$/ { d = 1; next } d && /^    [^ ]/ { d = 0 } d && /name:/ { print $NF }' "$values"
  [ "$output" = "$(printf 'Loki\nTempo')" ] || { echo "deleteDatasources: $output"; false; }
  grep -q '^  datasources.yaml:$' "$values"
  for f in platform/logging/loki/grafana-datasource.yaml platform/tracing/tempo/grafana-datasource.yaml \
    scenarios/observability-sre/manifests/grafana-datasources.yaml; do
    keys="$(grep -E '^  [a-z0-9.-]+\.yaml: \|$' "$ROOT/$f" | sed 's/^  //; s/: |$//')"
    [ -n "$keys" ] || { echo "no datasource file in $f"; false; }
    for key in $keys; do
      [[ "$key" > "datasources.yaml" ]] || { echo "$f: $key sorts before datasources.yaml"; false; }
    done
  done
}

datasource_apply_stub() {
  stub_script kubectl <<'EOF'
case "$*" in
  "apply --namespace obs -f -") cat >>"$STUB_DIR/applied.yaml" ;;
esac
EOF
}

@test "loki and tempo install apply their Grafana datasource in the monitoring namespace" {
  export MONITORING_NAMESPACE=obs
  for c in "logging/loki|loki|http://loki-gateway.obs.svc.cluster.local" \
    "tracing/tempo|tempo|http://tempo.obs.svc.cluster.local:3200"; do
    reset_calls
    rm -f "$STUB_DIR/applied.yaml"
    datasource_apply_stub
    run bash "$ROOT/platform/${c%%|*}/install.sh"
    [ "$status" -eq 0 ] || { echo "${c%%|*}: $output"; false; }
    applied="$STUB_DIR/applied.yaml"
    [ -s "$applied" ] || { echo "${c%%|*} applies no datasource"; false; }
    rest="${c#*|}"
    uid="${rest%%|*}"
    grep -q '^kind: ConfigMap$' "$applied" || { cat "$applied"; false; }
    grep -q "^  name: $uid-grafana-datasource\$" "$applied" || { cat "$applied"; false; }
    grep -q '^    grafana_datasource: "1"$' "$applied" || { cat "$applied"; false; }
    grep -q '^    prune: true$' "$applied" || { cat "$applied"; false; }
    grep -q "^        uid: $uid\$" "$applied" || { cat "$applied"; false; }
    grep -q "^        url: ${rest#*|}\$" "$applied" || { cat "$applied"; false; }
    run grep -n '\.monitoring\.svc' "$applied"
    [ "$status" -ne 0 ] || { echo "${c%%|*} keeps the default namespace: $output"; false; }
  done
}

# observability-sre installs its own Loki and Tempo when the platform has none,
# so it applies its own copy of their datasources. The copies must not drift.
@test "observability-sre's Grafana datasources match the platform's" {
  scenario="$ROOT/scenarios/observability-sre/manifests/grafana-datasources.yaml"
  grep -q 'path: manifests/grafana-datasources.yaml$' "$ROOT/scenarios/observability-sre/scenario.yaml"
  for c in "logging/loki|observability-sre-loki.yaml" "tracing/tempo|observability-sre-tempo.yaml"; do
    platform="$ROOT/platform/${c%%|*}/grafana-datasource.yaml"
    awk '/^    apiVersion: 1$/ { on = 1 } on' "$platform" >"$BATS_TEST_TMPDIR/platform"
    awk -v key="  ${c#*|}: |" '$0 == key { on = 1; next } /^---$/ { on = 0 } on' "$scenario" |
      sed 's/{{\.MonitoringNamespace}}/monitoring/g' >"$BATS_TEST_TMPDIR/scenario"
    [ -s "$BATS_TEST_TMPDIR/platform" ] || { echo "no datasource in ${platform#"$ROOT"/}"; false; }
    run diff "$BATS_TEST_TMPDIR/platform" "$BATS_TEST_TMPDIR/scenario"
    [ "$status" -eq 0 ] || { echo "${c%%|*}: $output"; false; }
  done
}

# client-go in helm and kubectl prints an error for each API group the
# apiserver cannot serve yet: the metrics API while metrics-server starts, and
# the CRDs a chart has just installed. labctl shows them only with --verbose.
discovery_noise_stub() {
  stub_script "$1" <<'EOF'
case "$*" in
  upgrade* | apply* | rollout*)
    echo "E1029 10:00:00.000000    4242 memcache.go:287] couldn't get resource list for metrics.k8s.io/v1beta1: the server is currently unable to handle the request" >&2
    echo "E1029 10:00:01.000000    4242 memcache.go:265] \"Unhandled Error\" err=\"couldn't get resource list for monitoring.coreos.com/v1: the server could not find the requested resource\" logger=\"UnhandledError\"" >&2
    if [ -n "${TOOL_FAILS:-}" ]; then
      echo "Error: $1 failed: the real problem" >&2
      exit 1
    fi
    echo "$1 done"
    ;;
esac
EOF
}

@test "helm and kubectl discovery errors are left out of the install output" {
  discovery_noise_stub helm
  discovery_noise_stub kubectl
  for c in ingress/traefik monitoring/metrics/prometheus; do
    reset_calls
    run bash "$ROOT/platform/$c/install.sh"
    [ "$status" -eq 0 ] || { echo "$c: $output"; false; }
    [[ "$output" == *"upgrade done"* ]] || { echo "$c: $output"; false; }
    [[ "$output" != *"couldn't get resource list"* ]] || { echo "$c: $output"; false; }
  done
}

@test "a real helm error still shows and still fails the install" {
  discovery_noise_stub helm
  TOOL_FAILS=1 run bash "$ROOT/platform/monitoring/metrics/prometheus/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: upgrade failed: the real problem"* ]] || false
  [[ "$output" != *"couldn't get resource list"* ]] || false
}

@test "a real kubectl error still shows and still fails the install" {
  discovery_noise_stub kubectl
  TOOL_FAILS=1 run bash "$ROOT/platform/monitoring/metrics/prometheus/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: apply failed: the real problem"* ]] || false
  [[ "$output" != *"couldn't get resource list"* ]] || false
}

@test "LABCTL_VERBOSE=1 keeps the discovery errors" {
  discovery_noise_stub helm
  discovery_noise_stub kubectl
  LABCTL_VERBOSE=1 run bash "$ROOT/platform/ingress/traefik/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"memcache.go:287] couldn't get resource list for metrics.k8s.io/v1beta1"* ]] || false
  [[ "$output" == *"couldn't get resource list for monitoring.coreos.com/v1: the server could not find"* ]] || false
}

# The first upgrade fails on an immutable StatefulSet field; the retry runs
# after the controller is deleted. Both print discovery errors.
statefulset_retry_helm() {
  stub_script helm <<'EOF'
case "$*" in
  upgrade*)
    echo "E1029 10:00:00.000000    4242 memcache.go:287] couldn't get resource list for metrics.k8s.io/v1beta1: the server is currently unable to handle the request" >&2
    if [ ! -f "$STUB_DIR/retried" ]; then
      touch "$STUB_DIR/retried"
      echo "Error: UPGRADE FAILED: cannot patch \"loki\" with kind StatefulSet: StatefulSet.apps \"loki\" is invalid: spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template' are forbidden" >&2
      exit 1
    fi
    if [ -n "${RETRY_FAILS:-}" ]; then
      echo "Error: UPGRADE FAILED: the retry failed too" >&2
      exit 1
    fi
    echo "upgrade done"
    ;;
esac
EOF
}

@test "the StatefulSet retry works with the discovery filter in place" {
  statefulset_retry_helm
  run bash -c 'set -euo pipefail; . "$1/platform/_lib/helm.sh"; helm_upgrade_install loki logging grafana-community/loki --namespace logging' _ "$ROOT"
  [ "$status" -eq 0 ]
  assert_called kubectl "delete statefulset loki --namespace logging --cascade=orphan"
  assert_call_count helm 2 "upgrade --install loki"
  [[ "$output" == *"upgrade done"* ]] || false
  [[ "$output" != *"couldn't get resource list"* ]] || false
}

@test "a failed StatefulSet retry still fails and shows helm's error" {
  statefulset_retry_helm
  RETRY_FAILS=1 run bash -c 'set -euo pipefail; . "$1/platform/_lib/helm.sh"; helm_upgrade_install loki logging grafana-community/loki --namespace logging' _ "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the retry failed too"* ]] || false
  [[ "$output" != *"couldn't get resource list"* ]] || false
}

# Promtail is end-of-life upstream; Alloy ships the logs (#46). One Alloy per
# node reads the log files the kubelet writes there.
@test "loki install ships logs with an alloy-logs DaemonSet, not Promtail" {
  stub_when helm "status promtail" 1
  export MONITORING_NAMESPACE=obs
  run bash "$ROOT/platform/logging/loki/install.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_called helm "upgrade --install alloy-logs grafana/alloy --namespace obs --version 1.12.1"
  assert_called kubectl "rollout status daemonset/alloy-logs -n obs"
  refute_called helm "grafana/promtail"
  refute_called helm "uninstall promtail"
}

# A lab built while Promtail shipped the logs keeps it until logging is
# reinstalled. Left running next to Alloy, it ships every line a second time.
@test "loki install removes a Promtail release left by an older lab" {
  stub_when helm "status promtail" 0 "STATUS: deployed"
  run bash "$ROOT/platform/logging/loki/install.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_called helm "uninstall promtail --namespace monitoring"
  [ "$(calls_for helm | grep -n 'upgrade --install alloy-logs' | cut -d: -f1)" -lt \
    "$(calls_for helm | grep -n 'uninstall promtail' | cut -d: -f1)" ] ||
    { echo "promtail goes before alloy-logs is up"; calls_for helm; false; }
}

# Without app and namespace on each stream, {app="go-api"} matches nothing and
# the dashboards read as broken. The relabel rules are what attach them.
@test "alloy-logs relabels the pod's app label and namespace onto each stream" {
  values="$ROOT/platform/logging/loki/alloy-logs-values.yaml"
  for rule in "__meta_kubernetes_pod_label_app|app" "__meta_kubernetes_namespace|namespace"; do
    run grep -A1 "source_labels = \[\"${rule%%|*}\"\]" "$values"
    [ "$status" -eq 0 ] || { echo "no rule reads ${rule%%|*}"; false; }
    [[ "$output" == *"target_label  = \"${rule#*|}\""* ]] || { echo "$output"; false; }
  done
  grep -q '^  type: daemonset$' "$values"
  grep -q 'url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"' "$values"
}

# observability-sre adopts the platform's log shipper rather than keeping a copy
# of its values, and checks it by the same name.
@test "observability-sre ships logs with the platform's alloy-logs release" {
  scenario="$ROOT/scenarios/observability-sre/scenario.yaml"
  grep -q 'platformValues: logging/loki/alloy-logs-values.yaml$' "$scenario"
  grep -q 'resource: daemonset/alloy-logs$' "$scenario"
  run grep -n 'promtail' "$scenario"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
}
