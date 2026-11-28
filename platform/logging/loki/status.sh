#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

echo "=== Loki Status ==="
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=loki 2>/dev/null || echo "Loki not found"

echo ""
echo "=== Alloy (log shipping) Status ==="
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance=alloy-logs 2>/dev/null || echo "Alloy not found"

echo ""
echo "=== Loki Services ==="
kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name=loki 2>/dev/null || echo "No Loki services"
