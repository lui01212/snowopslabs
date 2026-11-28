#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

# Grafana's sidecar drops the Loki datasource with its ConfigMap.
kubectl delete configmap loki-grafana-datasource --namespace "$NAMESPACE" --ignore-not-found

echo "Uninstalling Alloy (log shipping)..."
helm uninstall alloy-logs --namespace "$NAMESPACE" 2>/dev/null || true

# A lab built before the move to Alloy may still run Promtail.
helm uninstall promtail --namespace "$NAMESPACE" 2>/dev/null || true

echo "Uninstalling Loki..."
helm uninstall loki --namespace "$NAMESPACE" 2>/dev/null || true

# Clean up PVCs
kubectl delete pvc -l app.kubernetes.io/name=loki -n "$NAMESPACE" --ignore-not-found

echo "Loki + Alloy uninstalled."
