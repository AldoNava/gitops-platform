# 🚀 GitOps Platform — Multi-Tenant FluxCD on Kubernetes

Plataforma GitOps multi-tenant con FluxCD, control de ambientes por `main`, flujo de promoción con aprobación manual, y event-driven via GitHub webhooks. Diseñada para EKS, ejecutable en kubeadm local.

---

## 🏗️ Arquitectura

```
GitHub (main branch)
        │
        │ webhook push event (instantáneo)
        ▼
┌─────────────────────────────────────────────────────────┐
│  FluxCD (flux-system namespace)                          │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ GitRepository│  │Kustomization │  │   Receiver    │  │
│  │  flux-system │→ │  flux-system │  │github-receiver│  │
│  └──────────────┘  └──────┬───────┘  └───────────────┘  │
│                            │                              │
│               ┌────────────┼────────────┐                 │
│               ▼            ▼            ▼                 │
│         clusters/dev  clusters/test  clusters/preprod     │
└─────────────────────────────────────────────────────────┘
        │               │               │
        ▼               ▼               ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│  DEV         │ │  TEST        │ │  PREPROD     │
│  PSA:baseline│ │  PSA:privil. │ │  PSA:restrict│
│  HPA: 1-3   │ │  HPA: 2-5   │ │  HPA: 2-8   │
│  QoS:Guarant │ │  QoS:Guarant │ │  QoS:Guarant │
│              │ │              │ │              │
│ team-payments│ │ team-payments│ │ team-payments│
│ team-auth    │ │ team-auth    │ │ team-auth    │
│ team-gateway │ │ team-gateway │ │ team-gateway │
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                │
       └────────────────┴────────────────┘
                        │
                 NGINX Ingress (NodePort :30080)
                 API Gateway centralizado
                 ┌─────────────────────┐
                 │ /payments/* → team-payments
                 │ /auth/*     → team-auth
                 │ /gateway/*  → team-gateway
                 │ /healthz    → team-gateway
                 └─────────────────────┘
```

---

## 📁 Estructura del repositorio

```
gitops-platform/
├── .flux/
│   └── flux-system.yaml          # GitRepository + Kustomization raíz
├── .github/
│   └── workflows/
│       ├── promote-dev.yaml      # Auto-promote a DEV + abre PR para TEST
│       ├── promote-preprod.yaml  # Promote TEST→PREPROD con aprobación
│       └── validate-manifests.yaml # Validación en PRs
├── clusters/
│   ├── base/kustomization.yaml   # Entry point: infra + ambientes
│   ├── dev/kustomization.yaml    # Referencia tenants/*/dev
│   ├── test/kustomization.yaml   # Referencia tenants/*/test
│   └── preprod/kustomization.yaml
├── infrastructure/
│   ├── controllers/              # metrics-server patch, NGINX, webhook receiver
│   ├── ingress/                  # API Gateway Ingress por ambiente
│   └── monitoring/               # PodMonitor para todos los tenants
├── tenants/
│   ├── team-payments/
│   │   ├── base/                 # Deployment, Service, HPA, NetworkPolicy, SA, NS
│   │   ├── dev/kustomization.yaml    # ← PROMOTION POINT (image tag)
│   │   ├── test/kustomization.yaml   # ← PROMOTION POINT (requiere PR aprobado)
│   │   └── preprod/kustomization.yaml # ← PROMOTION POINT (requiere reviewer)
│   ├── team-auth/                # Misma estructura
│   └── team-gateway/             # Misma estructura
├── scripts/
│   └── bootstrap.sh              # Setup completo del cluster
├── docs/
│   └── OPERATIONS.md
├── .trigger-version              # Versión actual a promover
└── .gitignore
```

---

## 🔀 Flujo de Promoción (Combinado)

```
┌─────────────────────────────────────────────────────────────────────┐
│  DEVELOPER                                                           │
│  1. Actualiza .trigger-version con nuevo tag (ej: 6.7.0)            │
│  2. Commit + push a main                                             │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  GITHUB ACTIONS: promote-dev.yaml                                    │
│  ✅ Auto-actualiza tenants/*/dev/kustomization.yaml (newTag)         │
│  ✅ Commit + push → GitHub webhook notifica a Flux                   │
│  ✅ Flux reconcilia en < 30 segundos → DEV desplegado                │
│  ✅ Abre PR automático: "Promote 6.7.0 → TEST"                       │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         │ Reviewer hace code review del PR
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  REVIEWER aprueba y mergea PR a main                                 │
│  ✅ GitHub webhook notifica a Flux                                   │
│  ✅ Flux reconcilia → TEST desplegado                                │
│  ✅ promote-preprod.yaml se activa                                   │
│  ✅ GitHub Environment "preprod" bloquea hasta aprobación            │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         │ Reviewer aprueba en GitHub Environment UI
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  GITOPS BOT abre PR: "Promote 6.7.0 → PREPROD"                      │
│  ✅ Reviewer aprueba y mergea                                        │
│  ✅ Flux reconcilia → PREPROD desplegado                             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## ⚡ Event-Driven: Webhook Receiver

El Receiver de Flux expone un endpoint HTTP que GitHub llama en cada `push`:

```
GitHub push → POST http://<TAILSCALE_IP>:31234/hook/<TOKEN_HASH>
                                    │
                              Flux Receiver
                                    │
                         Reconcilia GitRepository
                                    │
                         Aplica Kustomizations
                                    │
                         Deploy en < 30 segundos
```

### Obtener la URL del webhook

```bash
# Obtener el path del receiver (contiene el token hash)
kubectl get receiver github-receiver -n flux-system \
  -o jsonpath='{.status.webhookPath}'

# Obtener tu IP de Tailscale
ip -4 addr show tailscale0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'

# URL final:
# http://<TAILSCALE_IP>:31234<WEBHOOK_PATH>
```

---

## 🛡️ Seguridad por Capa

### Pod Security Admission (PSA)

| Ambiente | Nivel | Efecto |
|----------|-------|--------|
| DEV | `baseline` | Permite la mayoría de workloads, bloquea lo más peligroso |
| TEST | `privileged` | Sin restricciones para testing exhaustivo |
| PREPROD | `restricted` | Máximas restricciones, simula producción |

### QoS Classes

Todos los pods tienen `requests == limits` → **QoS Guaranteed**

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 100m    # igual al request
    memory: 128Mi # igual al request
```

Esto asegura que el scheduler de Kubernetes no evicte pods bajo presión de memoria.

### NetworkPolicies (Calico)

```
team-payments-dev  ←X→  team-auth-test    # Cross-environment: BLOQUEADO
team-payments-dev  ←✓→  team-auth-dev     # Same-environment: PERMITIDO
team-payments-dev  ←X→  team-gateway-dev  # Gateway es quien inicia, no payments
ingress-nginx      ←✓→  todos los tenants # Solo NGINX puede llegar desde fuera
```

---

## 🚀 Quick Start

### 1. Clonar y configurar

```bash
git clone https://github.com/AldoNava/gitops-platform.git
cd gitops-platform
```

### 2. Bootstrap del cluster

```bash
export GITHUB_TOKEN="ghp_tu_token_aqui"
export GITHUB_USER="AldoNava"
export GITHUB_REPO="gitops-platform"
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

### 3. Configurar GitHub webhook

Después del bootstrap, el script te mostrará la URL del webhook. Ve a:
`https://github.com/AldoNava/gitops-platform/settings/hooks`

Y agrega:
- **Payload URL**: `http://<TAILSCALE_IP>:31234/hook/<TOKEN_HASH>`
- **Content type**: `application/json`
- **Secret**: (el que generó el script)
- **Events**: Just the push event

### 4. Configurar GitHub Environment para PREPROD

Ve a `Settings → Environments → New environment → preprod`
- Marca: **Required reviewers**
- Agrega: `AldoNava` (o tu usuario)

### 5. Configurar GitHub Secrets

```
Settings → Secrets and variables → Actions → New secret

GITOPS_PAT = <tu GitHub PAT con permisos repo + workflow>
```

### 6. Agregar hosts en tu cliente

```bash
# En la máquina desde donde accedes (no la VM)
echo "<TAILSCALE_IP>  api-dev.local api-test.local api-preprod.local" | sudo tee -a /etc/hosts
```

### 7. Verificar

```bash
# Ver estado de Flux
flux get all --all-namespaces

# Ver pods por ambiente
kubectl get pods -A | grep team-

# Probar API Gateway
curl http://api-dev.local:30080/payments/
curl http://api-dev.local:30080/auth/
curl http://api-dev.local:30080/healthz
```

---

## 🔧 Operaciones comunes

### Promover una nueva versión

```bash
# 1. Actualizar el tag
echo "6.7.0" > .trigger-version

# 2. Commit y push (dispara el flujo automático)
git add .trigger-version
git commit -m "feat: promote podinfo 6.7.0"
git push origin main
```

### Forzar reconciliación de Flux

```bash
flux reconcile source git flux-system
flux reconcile kustomization flux-system
```

### Ver logs de Flux

```bash
# Source controller (detecta cambios en Git)
kubectl logs -n flux-system deploy/source-controller -f

# Kustomize controller (aplica manifests)
kubectl logs -n flux-system deploy/kustomize-controller -f

# Notification controller (webhooks)
kubectl logs -n flux-system deploy/notification-controller -f
```

### Rollback de un ambiente

```bash
# Revertir el tag en el overlay del ambiente afectado
# Ejemplo: rollback payments en preprod a 6.6.0
sed -i 's/newTag: "6.7.0"/newTag: "6.6.0"/' tenants/team-payments/preprod/kustomization.yaml
git add tenants/team-payments/preprod/kustomization.yaml
git commit -m "fix(preprod): rollback payments to 6.6.0"
git push origin main
# Flux detecta el push y aplica el rollback en < 30s
```

### Verificar NetworkPolicies

```bash
# Test: payments en dev NO puede hablar con auth en test
kubectl run test-pod --rm -it --image=busybox \
  --namespace=team-payments-dev \
  -- wget -qO- --timeout=3 http://auth-api.team-auth-test.svc.cluster.local:8080/healthz
# Debe fallar (timeout) ← comportamiento esperado

# Test: payments en dev SÍ puede hablar con auth en dev
kubectl run test-pod --rm -it --image=busybox \
  --namespace=team-payments-dev \
  -- wget -qO- --timeout=3 http://auth-api.team-auth-dev.svc.cluster.local:8080/healthz
# Debe retornar {"status":"ok"} ← comportamiento esperado
```

### Verificar QoS

```bash
kubectl get pods -n team-payments-dev -o custom-columns=\
"NAME:.metadata.name,QOS:.status.qosClass"
# Todos deben mostrar: Guaranteed
```

### Verificar HPA

```bash
kubectl get hpa -A
# MINPODS y MAXPODS deben reflejar los valores del ambiente
```

---

## 🗺️ Roadmap a EKS

Para migrar este setup a EKS, los cambios son mínimos:

| Componente | Local (kubeadm) | EKS |
|------------|-----------------|-----|
| Ingress | NodePort :30080 | AWS ALB Controller |
| ServiceAccount | Sin annotations | IRSA: `eks.amazonaws.com/role-arn` |
| Webhook URL | Tailscale IP | ALB DNS o API GW |
| Calico CNI | Calico OSS | VPC CNI + Calico para NetworkPolicies |
| metrics-server | `--kubelet-insecure-tls` | Sin flag (cert válido en EKS) |
| Secrets | kubectl create secret | External Secrets Operator → AWS Secrets Manager |

---

## 📦 Stack tecnológico

| Componente | Herramienta | Versión |
|------------|-------------|---------|
| GitOps engine | FluxCD | v2.x |
| Package manager | Helm | v3.x |
| Ingress / API GW | NGINX Ingress Controller | 4.x |
| Autoscaling | Kubernetes HPA (autoscaling/v2) | nativo |
| Network policies | Calico | instalado |
| Security | Pod Security Admission | nativo k8s |
| CI/CD | GitHub Actions | cloud |
| Registry | Docker Hub | cloud |
| Tunnel local | Tailscale Funnel | instalado |
| Workload demo | podinfo (stefanprodan) | 6.6.0 |
