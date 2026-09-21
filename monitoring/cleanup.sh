#!/bin/bash
# ============================================================================
# LAIR MONITORING CLEANUP
# ============================================================================
# Removes the entire monitoring stack:
#   - Prometheus + Grafana + Alertmanager (kube-prometheus-stack)
#   - Loki
#   - Promtail
#   - Namespace 'monitoring' and all its PVCs
# ============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
MONITORING_NS="monitoring"

info()    { echo -e "${CYAN}ℹ️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

# Preflight
command -v helm    >/dev/null 2>&1 || error "helm is not installed"
command -v kubectl >/dev/null 2>&1 || error "kubectl is not installed"
kubectl cluster-info >/dev/null 2>&1 || error "Cannot reach Kubernetes cluster"

# Check if monitoring is installed
if ! kubectl get ns "$MONITORING_NS" >/dev/null 2>&1; then
    info "Monitoring namespace not found. Nothing to clean up."
    exit 0
fi

echo ""
echo -e "${RED}⚠️  This will REMOVE the entire monitoring stack:${NC}"
echo "   - Prometheus (all metrics history will be lost)"
echo "   - Grafana (all dashboards and configs)"
echo "   - Loki (all collected logs)"
echo "   - Promtail"
echo "   - Namespace '$MONITORING_NS' and all PVCs"
echo ""
echo -e "${YELLOW}   This action is IRREVERSIBLE!${NC}"
echo ""
read -p "Type 'yes' to confirm removal: " CONFIRM
[ "$CONFIRM" != "yes" ] && { echo "Cancelled."; exit 0; }

echo ""
info "Uninstalling Helm releases..."
helm uninstall lair-promtail   --namespace "$MONITORING_NS" 2>/dev/null || true
helm uninstall lair-loki       --namespace "$MONITORING_NS" 2>/dev/null || true
helm uninstall lair-monitoring --namespace "$MONITORING_NS" 2>/dev/null || true
success "Helm releases uninstalled."

info "Deleting namespace and remaining resources..."
kubectl delete namespace "$MONITORING_NS" --timeout=120s 2>/dev/null || true
success "Namespace deleted."

echo ""
success "✅ Monitoring Stack completely removed."
