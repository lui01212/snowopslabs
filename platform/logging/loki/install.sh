#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../_lib/helm.sh
. "$(cd "$SCRIPT_DIR/../.." && pwd)/_lib/helm.sh"
ALLOY_VALUES_FILE="$(mktemp "${TMPDIR:-/tmp}/alloy-logs-values.XXXXXX")"
trap 'rm -f "$ALLOY_VALUES_FILE"' EXIT

# Log retention: default 7 days (168h). Set LOKI_RETENTION_HOURS to override.
# Set to 0 to disable retention (logs never expire).
RETENTION_HOURS="${LOKI_RETENTION_HOURS:-168}"
GRAFANA_CHARTS_REPO="${GRAFANA_CHARTS_REPO:-https://grafana-community.github.io/helm-charts}"
ALLOY_CHARTS_REPO="${ALLOY_CHARTS_REPO:-https://grafana.github.io/helm-charts}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-18.12.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.12.1}"
if [ "$RETENTION_HOURS" = "0" ]; then
  RETENTION_PERIOD="0s"
else
  RETENTION_PERIOD="${RETENTION_HOURS}h"
fi

echo "Installing Loki (single-binary mode, namespace=${NAMESPACE}, retention=${RETENTION_PERIOD})..."

# Loki's chart is maintained in grafana-community; Alloy's is in the original
# grafana repo.
helm repo add grafana-community "$GRAFANA_CHARTS_REPO" --force-update
helm repo add grafana "$ALLOY_CHARTS_REPO" --force-update
helm repo update grafana-community grafana

# Clean up stuck pending releases if any
if helm status loki -n "$NAMESPACE" 2>/dev/null | grep -q "pending-"; then
  echo "Cleaning up stuck Loki release..."
  helm delete loki -n "$NAMESPACE" --wait 2>/dev/null || true
fi

# Install with runtime retention override. Using --set (not sed -i) keeps the
# script portable across macOS and Linux (avoids GNU-only sed -i behaviour).
helm_upgrade_install loki "$NAMESPACE" grafana-community/loki \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --version "$LOKI_CHART_VERSION" \
  -f "$SCRIPT_DIR/values.yaml" \
  --set "loki.limits_config.retention_period=${RETENTION_PERIOD}" \
  --set "singleBinary.persistence.storageClass=${STORAGE_CLASS:-local-path}" \
  --wait --timeout 5m

echo "Waiting for Loki to be ready..."
kubectl rollout status statefulset/loki -n "$NAMESPACE" --timeout=120s || true

# Grafana's Loki datasource, loaded by Grafana's datasource sidecar. It lives
# here, not in grafana's values, so a lab without logging lists no Loki.
echo "Adding the Loki datasource to Grafana..."
sed "s/\.monitoring\.svc/.${NAMESPACE}.svc/g" "$SCRIPT_DIR/grafana-datasource.yaml" |
  kubectl apply --namespace "$NAMESPACE" -f -

echo "Installing Alloy (log shipping)..."

# Render alloy-logs-values.yaml with the real monitoring namespace.
sed "s/\.monitoring\.svc/.${NAMESPACE}.svc/g" "$SCRIPT_DIR/alloy-logs-values.yaml" >"$ALLOY_VALUES_FILE"

# Clean up stuck pending releases if any
if helm status alloy-logs -n "$NAMESPACE" 2>/dev/null | grep -q "pending-"; then
  echo "Cleaning up stuck Alloy release..."
  helm delete alloy-logs -n "$NAMESPACE" --wait 2>/dev/null || true
fi

helm_upgrade_install alloy-logs "$NAMESPACE" grafana/alloy \
  --namespace "$NAMESPACE" \
  --version "$ALLOY_CHART_VERSION" \
  -f "$ALLOY_VALUES_FILE" \
  --wait --timeout 5m

echo "Waiting for Alloy to be ready..."
kubectl rollout status daemonset/alloy-logs -n "$NAMESPACE" --timeout=120s || true

# A lab built before the move to Alloy still runs Promtail. Left in place it
# ships every line a second time, so it goes once Alloy is up.
if helm status promtail -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Removing Promtail, replaced by Alloy..."
  helm uninstall promtail --namespace "$NAMESPACE" --wait 2>/dev/null || true
fi

echo "Loki + Alloy installed successfully."
