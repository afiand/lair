#!/bin/bash
# ============================================================================
# LAIR MONITORING SETUP - Prometheus + Grafana + Loki
# ============================================================================
# Installs the full observability stack for LAiR:
#   - Prometheus (metrics, 15d retention)
#   - Grafana (dashboards + log viewer)
#   - Loki (log aggregation, 7d retention)
#   - Promtail (log collection from all pods)
#   - Alertmanager (basic threshold alerts)
#   - node-exporter + kube-state-metrics
# ============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MONITORING_NS="monitoring"
GRAFANA_PORT_NODEPORT=30300

info()    { echo -e "${CYAN}ℹ️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ─── Preflight ───────────────────────────────────────────────────────────────
preflight() {
    info "Running preflight checks..."
    command -v helm    >/dev/null 2>&1 || error "helm is not installed. Install it first."
    command -v kubectl >/dev/null 2>&1 || error "kubectl is not installed. Install it first."
    kubectl cluster-info >/dev/null 2>&1 || error "Cannot reach Kubernetes cluster. Check kubeconfig."
    kubectl get ns lair >/dev/null 2>&1 || error "Namespace 'lair' not found. Deploy the Lair app first (setup.sh → option 2)."
    success "All preflight checks passed."
}

# ─── Detect platform ─────────────────────────────────────────────────────────
detect_platform() {
    STORAGE_CLASS=""
    if kubectl get ns 2>/dev/null | grep -q "longhorn-system"; then
        STORAGE_CLASS="lair-storage"
        info "Detected MicroK8s/LAN platform (Longhorn storage available)"
    else
        info "Detected managed/cloud platform (using default storage class)"
    fi
}

# ─── Ask configuration ───────────────────────────────────────────────────────
ask_config() {
    echo ""
    info "🔐 Grafana Authentication:"
    read -sp "   Admin password (press Enter for random): " GRAFANA_PASSWORD
    if [ -z "$GRAFANA_PASSWORD" ]; then
        GRAFANA_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
        info "   Generated random password: $GRAFANA_PASSWORD"
        warn "   Save this password! You need it to access Grafana."
    fi

    echo ""
    read -p "   Prometheus retention [default: 15d]: " PROM_RETENTION
    PROM_RETENTION=${PROM_RETENTION:-15d}

    read -p "   Loki retention [default: 7d]: " LOKI_RETENTION
    LOKI_RETENTION=${LOKI_RETENTION:-7d}

    echo ""
    info "🌐 Access method:"
    echo "   1) NodePort (recommended - simple, works on LAN and cloud)"
    echo "   2) Ingress (requires a domain and ingress-nginx/traefik)"
    read -p "   Choice [1]: " ACCESS_METHOD
    ACCESS_METHOD=${ACCESS_METHOD:-1}

    INGRESS_DOMAIN=""
    if [ "$ACCESS_METHOD" == "2" ]; then
        read -p "   Grafana domain (e.g. grafana.lair.local): " INGRESS_DOMAIN
        [ -z "$INGRESS_DOMAIN" ] && error "Ingress domain cannot be empty"
    fi
}

# ─── Install components ──────────────────────────────────────────────────────
install_components() {
    echo ""
    info "📦 Creating namespace '$MONITORING_NS'..."
    kubectl create namespace "$MONITORING_NS" --dry-run=client -o yaml | kubectl apply -f -

    info "📦 Adding Helm repositories..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo update >/dev/null 2>&1 || true

    # Build extra flags for storage class
    local EXTRA_ARGS=""
    if [ -n "$STORAGE_CLASS" ]; then
        EXTRA_ARGS="--set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=$STORAGE_CLASS"
    fi

    info "🚀 Installing kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."
    helm upgrade --install lair-monitoring prometheus-community/kube-prometheus-stack \
        --namespace "$MONITORING_NS" \
        -f "$SCRIPT_DIR/values/prometheus-values.yaml" \
        --set grafana.admin.password="$GRAFANA_PASSWORD" \
        --set prometheus.prometheusSpec.retention="$PROM_RETENTION" \
        $EXTRA_ARGS \
        --wait --timeout 15m

    info "🚀 Installing Loki..."
    helm upgrade --install lair-loki grafana/loki \
        --namespace "$MONITORING_NS" \
        -f "$SCRIPT_DIR/values/loki-values.yaml" \
        --wait --timeout 15m

    info "🚀 Installing Promtail..."
    helm upgrade --install lair-promtail grafana/promtail \
        --namespace "$MONITORING_NS" \
        -f "$SCRIPT_DIR/values/promtail-values.yaml" \
        --wait --timeout 15m

    success "All Helm releases installed."
}

# ─── Provision Grafana ───────────────────────────────────────────────────────
provision_grafana() {
    echo ""
    info "📊 Configuring Grafana datasources..."
    kubectl create configmap lair-grafana-datasources \
        --from-file=datasources.yaml="$SCRIPT_DIR/provisioning/datasources.yaml" \
        --namespace "$MONITORING_NS" --dry-run=client -o yaml | kubectl apply -f -

    info "📊 Provisioning dashboards..."
    kubectl create configmap lair-grafana-dashboards \
        --from-file=01-infrastructure.json="$SCRIPT_DIR/dashboards/01-infrastructure.json" \
        --from-file=02-services.json="$SCRIPT_DIR/dashboards/02-services.json" \
        --from-file=03-logs.json="$SCRIPT_DIR/dashboards/03-logs.json" \
        --namespace "$MONITORING_NS" \
        --label=grafana_dashboard=true \
        --dry-run=client -o yaml | kubectl apply -f -

    info "🚨 Applying alert rules..."
    kubectl apply -f "$SCRIPT_DIR/rules/lair-alerts.yaml"

    success "Grafana provisioning complete."
}

# ─── Create optional Ingress ─────────────────────────────────────────────────
create_ingress() {
    if [ "$ACCESS_METHOD" != "2" ] || [ -z "$INGRESS_DOMAIN" ]; then
        return 0
    fi

    echo ""
    info "🌐 Creating Ingress for Grafana ($INGRESS_DOMAIN)..."
    local INGRESS_CLASS="nginx"
    # Detect ingress class
    if kubectl get ns 2>/dev/null | grep -q "ingress-nginx"; then
        INGRESS_CLASS="nginx"
    elif kubectl get ingressclass 2>/dev/null | grep -q "traefik"; then
        INGRESS_CLASS="traefik"
    fi

    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: lair-grafana
  namespace: $MONITORING_NS
  labels:
    app: lair-monitoring
spec:
  ingressClassName: $INGRESS_CLASS
  rules:
  - host: $INGRESS_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: lair-monitoring-grafana
            port:
              number: 80
EOF
    success "Ingress created."
}

# ─── Wait & Verify ───────────────────────────────────────────────────────────
wait_ready() {
    echo ""
    info "⏳ Verifying all pods are running..."
    kubectl get pods -n "$MONITORING_NS" --no-headers || true
    sleep 5
    local FAILED
    FAILED=$(kubectl get pods -n "$MONITORING_NS" --no-headers 2>/dev/null | grep -cv "Running\|Completed" || true)
    if [ "$FAILED" -gt 0 ]; then
        warn "Some pods may still be starting. Check with: kubectl get pods -n $MONITORING_NS"
    else
        success "All pods are running."
    fi
}

# ─── Print access info ───────────────────────────────────────────────────────
print_access() {
    local NODE_IP
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            ✅ LAIR MONITORING STACK INSTALLED                ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    if [ "$ACCESS_METHOD" == "1" ]; then
        echo -e "${CYAN}║  Grafana:   http://$NODE_IP:$GRAFANA_PORT_NODEPORT              ║${NC}"
    else
        echo -e "${CYAN}║  Grafana:   http://$INGRESS_DOMAIN                            ║${NC}"
    fi
    echo -e "${CYAN}║  User:      admin                                            ║${NC}"
    echo -e "${CYAN}║  Password:  $GRAFANA_PASSWORD                                    ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Dashboards: Infrastructure | Services | Logs                ║${NC}"
    echo -e "${CYAN}║  Alerting:   Basic thresholds (CPU, Mem, Disk, Pods)        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "Next steps:"
    info "  - Open Grafana in your browser"
    info "  - Explore the 3 dashboards in the 'LAiR' folder"
    info "  - Check Alertmanager for any active alerts"
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}📊 LAIR MONITORING SETUP${NC}"
    echo "   Prometheus + Grafana + Loki for metrics and log aggregation"
    echo ""
    echo "   This will install:"
    echo "   • Prometheus (metrics collection, 15d retention)"
    echo "   • Grafana (visualization + log viewer)"
    echo "   • Loki (log aggregation, 7d retention)"
    echo "   • Promtail (log collection from all LAiR pods)"
    echo "   • Alertmanager (basic threshold alerts)"
    echo "   • node-exporter + kube-state-metrics"
    echo ""
    read -p "Continue? (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && { echo "Cancelled."; exit 0; }

    preflight
    detect_platform
    ask_config
    install_components
    provision_grafana
    create_ingress
    wait_ready
    print_access
}

main "$@"
