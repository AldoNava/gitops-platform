#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - Setup completo del GitOps Platform en kubeadm single-node
# =============================================================================
# Uso: ./scripts/bootstrap.sh
# Requisitos: kubectl, flux CLI, helm instalados en Ubuntu 24.04
# Cluster: kubeadm single-node con Calico CNI
# =============================================================================

set -euo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()   { echo -e "${BLUE}[ℹ]${NC} $1"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ── Variables ─────────────────────────────────────────────────────────────────
GITHUB_USER="${GITHUB_USER:-AldoNava}"
GITHUB_REPO="${GITHUB_REPO:-gitops-platform}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"   # Se lee de env var o se pide interactivo
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"

# ── Pre-checks ────────────────────────────────────────────────────────────────
header "Pre-flight checks"

command -v kubectl  &>/dev/null || error "kubectl no encontrado"
command -v flux     &>/dev/null || error "flux CLI no encontrado"
command -v helm     &>/dev/null || error "helm no encontrado"

log "Herramientas encontradas"

# Verificar cluster
kubectl cluster-info &>/dev/null || error "No se puede conectar al cluster. Verifica kubeconfig."
NODE_STATUS=$(kubectl get nodes --no-headers | awk '{print $2}')
[[ "$NODE_STATUS" == "Ready" ]] || error "Nodo no está en estado Ready: $NODE_STATUS"
log "Cluster OK - Nodo: $(kubectl get nodes --no-headers | awk '{print $1}') ($NODE_STATUS)"

# Verificar Calico
CALICO_PODS=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")
[[ "$CALICO_PODS" -gt 0 ]] || warn "Calico no encontrado - NetworkPolicies no funcionarán"
log "Calico OK ($CALICO_PODS pods running)"

# ── GitHub Token ─────────────────────────────────────────────────────────────
header "GitHub Configuration"

if [[ -z "$GITHUB_TOKEN" ]]; then
  warn "GITHUB_TOKEN no definido en environment"
  read -s -p "Ingresa tu GitHub PAT (permisos: repo, workflow): " GITHUB_TOKEN
  echo ""
fi

if [[ -z "$WEBHOOK_SECRET" ]]; then
  WEBHOOK_SECRET=$(openssl rand -hex 20)
  warn "WEBHOOK_SECRET generado automáticamente: $WEBHOOK_SECRET"
  warn "Guárdalo - lo necesitas para configurar el webhook en GitHub"
fi

log "GitHub user: $GITHUB_USER"
log "GitHub repo: $GITHUB_REPO"

# ── Crear GitHub Labels ───────────────────────────────────────────────────────
header "GitHub Labels"

# Instalar gh CLI si no está disponible
if ! command -v gh &>/dev/null; then
  info "Instalando gh CLI..."
  sudo apt install gh -y
fi

# Autenticar gh con el PAT
echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null

# Crear labels (--force evita error si ya existen)
gh label create promotion --color 0075ca --repo $GITHUB_USER/$GITHUB_REPO --force
gh label create test      --color e4e669 --repo $GITHUB_USER/$GITHUB_REPO --force
gh label create preprod   --color d93f0b --repo $GITHUB_USER/$GITHUB_REPO --force

log "GitHub labels creados"

# ── Fix metrics-server ────────────────────────────────────────────────────────
header "Fix metrics-server (kubeadm single-node)"

METRICS_STATUS=$(kubectl get pods -n kube-system -l k8s-app=metrics-server --no-headers 2>/dev/null | awk '{print $3}' || echo "NotFound")

if [[ "$METRICS_STATUS" != "Running" ]]; then
  info "metrics-server está en estado: $METRICS_STATUS. Aplicando patch..."
  kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--kubelet-insecure-tls"
    }
  ]' 2>/dev/null || warn "No se pudo patchear metrics-server (puede que ya tenga el flag)"
  
  info "Esperando metrics-server..."
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s || warn "metrics-server no ready en 120s"
  log "metrics-server OK"
else
  log "metrics-server ya está Running"
fi

# ── Crear Secrets para Flux ───────────────────────────────────────────────────
header "Creating Flux secrets"

# Crear namespace flux-system si no existe
kubectl get namespace flux-system &>/dev/null || kubectl create namespace flux-system
log "Namespace flux-system OK"

# Secret con GitHub PAT (para que Flux pueda leer/escribir el repo)
kubectl create secret generic flux-system \
  --namespace flux-system \
  --from-literal=username=$GITHUB_USER \
  --from-literal=password=$GITHUB_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -
log "Secret flux-system (GitHub PAT) creado"

# Secret para webhook receiver
kubectl create secret generic github-webhook-token \
  --namespace flux-system \
  --from-literal=token=$WEBHOOK_SECRET \
  --dry-run=client -o yaml | kubectl apply -f -
log "Secret github-webhook-token creado"

# Secret para GitHub status notifications (mismo PAT)
kubectl create secret generic github-token \
  --namespace flux-system \
  --from-literal=token=$GITHUB_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -
log "Secret github-token (notifications) creado"

# ── Bootstrap FluxCD ─────────────────────────────────────────────────────────
header "Bootstrap FluxCD"

info "Verificando si Flux ya está instalado..."
if kubectl get namespace flux-system &>/dev/null && kubectl get deployment -n flux-system source-controller &>/dev/null 2>&1; then
  warn "Flux ya está instalado. Ejecutando reconciliación..."
  flux reconcile source git flux-system
else
  info "Instalando Flux via bootstrap..."
  flux bootstrap github \
    --owner=$GITHUB_USER \
    --repository=$GITHUB_REPO \
    --branch=main \
    --path=./clusters/base \
    --personal \
    --token-auth \
    --components-extra=image-reflector-controller,image-automation-controller
fi

log "FluxCD bootstrap completado"

# ── Configurar NodePort para Webhook Receiver ─────────────────────────────────
header "Webhook Receiver setup"

# Esperar a que el notification-controller esté listo
info "Esperando notification-controller..."
kubectl rollout status deployment/notification-controller -n flux-system --timeout=120s

# Aplicar el Service NodePort para el receiver
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: webhook-receiver
  namespace: flux-system
spec:
  type: NodePort
  selector:
    app: notification-controller
  ports:
    - name: http
      port: 80
      targetPort: 9292
      nodePort: 31234
YAML

log "Webhook receiver NodePort (31234) configurado"

# Obtener el token hash del receiver (necesario para la URL del webhook)
info "Esperando al Receiver para obtener la URL del webhook..."
sleep 10
RECEIVER_URL=$(kubectl get receiver github-receiver -n flux-system -o jsonpath='{.status.webhookPath}' 2>/dev/null || echo "pendiente")
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
TAILSCALE_IP=$(ip -4 addr show tailscale0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "<TAILSCALE_IP>")

echo ""
warn "════════════════════════════════════════════════════"
warn "  CONFIGURACIÓN REQUERIDA EN GITHUB:"
warn "════════════════════════════════════════════════════"
warn "  Ve a: https://github.com/$GITHUB_USER/$GITHUB_REPO/settings/hooks"
warn "  Add webhook:"
warn "    Payload URL: http://$TAILSCALE_IP:31234$RECEIVER_URL"
warn "    Content type: application/json"
warn "    Secret: $WEBHOOK_SECRET"
warn "    Events: Just the push event"
warn "════════════════════════════════════════════════════"
echo ""

# ── Verificar despliegue ──────────────────────────────────────────────────────
# ── Aplicar Kustomizations de infraestructura ─────────────────────────────────
header "Infrastructure Kustomizations"

info "Aplicando Kustomizations de infraestructura a Flux..."

# Aplicar las kustomizations que Flux gestionará
kubectl apply -f .flux/infrastructure-controllers.yaml 2>/dev/null || true
kubectl apply -f .flux/infrastructure-ingress.yaml 2>/dev/null || true

info "Esperando a que flux-system esté ready antes de reconciliar infraestructura..."
flux reconcile kustomization flux-system --with-source

info "Reconciliando infrastructure-controllers (NGINX + metrics-server)..."
flux reconcile kustomization infrastructure-controllers 2>/dev/null || \
  warn "infrastructure-controllers aún no ready, Flux lo reintentará automáticamente"

info "Reconciliando infrastructure-ingress (API Gateway Ingress)..."
flux reconcile kustomization infrastructure-ingress 2>/dev/null || \
  warn "infrastructure-ingress aún no ready, Flux lo reintentará automáticamente"

info "Esperando NGINX Ingress Controller..."
kubectl wait --for=condition=available deployment \
  -l "app.kubernetes.io/name=ingress-nginx" \
  -n ingress-nginx \
  --timeout=180s 2>/dev/null || warn "NGINX no ready en 180s, verificar manualmente"

log "Infrastructure Kustomizations aplicadas"
header "Verification"

info "Esperando a que Flux reconcilie los recursos..."
sleep 30

echo ""
info "Estado de Flux:"
flux get all --all-namespaces 2>/dev/null || warn "Flux aún reconciliando..."

echo ""
info "Namespaces creados:"
kubectl get namespaces | grep -E "team-|ingress|flux"

echo ""
info "Pods por ambiente:"
for ns in team-payments-dev team-auth-dev team-gateway-dev; do
  echo "  [$ns]"
  kubectl get pods -n $ns 2>/dev/null || echo "    (namespace aún no creado)"
done

echo ""
log "════════════════════════════════════════════════════"
log "  Bootstrap completado!"
log "════════════════════════════════════════════════════"
log "  API Gateway DEV:    http://$TAILSCALE_IP:30080"
log "  API Gateway TEST:   http://$TAILSCALE_IP:30080 (host: api-test.local)"
log "  Webhook receiver:   http://$TAILSCALE_IP:31234$RECEIVER_URL"
log ""
log "  Agrega a tu /etc/hosts (en tu máquina cliente):"
log "    $TAILSCALE_IP  api-dev.local api-test.local api-preprod.local"
log "════════════════════════════════════════════════════"
echo ""
info "Siguientes pasos: ver docs/OPERATIONS.md"
