# gitops-platform

Multi-tenant GitOps platform with FluxCD. See [docs/OPERATIONS.md](docs/OPERATIONS.md) for full documentation.

## Quick start

```bash
export GITHUB_TOKEN="ghp_..."
./scripts/bootstrap.sh
```

## Tenants

| Tenant | Color | Puerto API |
|--------|-------|------------|
| team-payments | 🟢 Verde | /payments/* |
| team-auth | 🔵 Azul | /auth/* |
| team-gateway | 🟠 Naranja | /gateway/* |

## Ambientes

| Ambiente | PSA | HPA | Auto-deploy |
|----------|-----|-----|-------------|
| dev | baseline | 1-3 | ✅ automático |
| test | privileged | 2-5 | 🔐 PR aprobado |
| preprod | restricted | 2-8 | 🔐 reviewer requerido |
