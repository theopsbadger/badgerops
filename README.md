# badgerops

A GKE-based homelab Kubernetes cluster with a full GitOps stack running on GCP.

## Stack

### Infrastructure
| Component | Details |
|---|---|
| **GKE Standard** | Zonal cluster (us-central1-a), e2-standard-2 nodes, autoscaling 2–4 nodes |
| **Networking** | Private nodes, Cloud NAT, VPC-native pod networking |
| **Workload Identity** | GKE Workload Identity for pod-level GCP auth (used by ESO) |
| **Terraform** | Provisions GKE cluster, node pool, networking, and seeds ArgoCD + ESO IAM |

### Platform
| Component | Version | Purpose |
|---|---|---|
| **ArgoCD** | 9.5.0 (Helm) | GitOps controller — manages all apps via ApplicationSet |
| **Kargo** | 1.9.0 (Helm) | Promotion engine — moves Freight (images, commits) across Stages |
| **Istio** | 1.24.3 | Service mesh, north-south ingress via Kubernetes Gateway API |
| **cert-manager** | — | Automated TLS certificates via Cloudflare DNS-01 |
| **External Secrets Operator** | — | Syncs secrets from GCP Secret Manager |
| **Kyverno** | 3.7.1 | Policy enforcement (audit mode) |
| **Kiali** | — | Istio observability dashboard |

### Observability
| Component | Purpose |
|---|---|
| **kube-prometheus-stack** | Prometheus, Grafana, Alertmanager, node-exporter |
| **prometheus-operator-crds** | Separate app — CRDs must exist before the stack deploys |

### Applications
| App | URL | Notes |
|---|---|---|
| **ArgoCD** | argocd.k8s.badgerops.io | GitHub SSO via Dex — any GitHub user gets readonly, admins explicit |
| **Kargo** | kargo.k8s.badgerops.io | GitHub SSO via Dex — promotion UI |
| **Grafana** | grafana.k8s.badgerops.io | GitHub SSO, includes custom dashboards |
| **Kiali** | kiali.k8s.badgerops.io | Istio mesh topology |
| **podinfo** | podinfo.k8s.badgerops.io | Demo app with backend ping, HPA, ServiceMonitor |
| **Online Boutique** | shop.k8s.badgerops.io | Google microservices demo (11 services) |
| **Argo Rollouts** | rollouts.k8s.badgerops.io | Progressive delivery controller + dashboard |
| **Bookinfo** | bookinfo.k8s.badgerops.io | Istio sample app |
| **Consul** | — | Service catalog sync only (no sidecar injection) |

## Repository structure

```
.
├── terraform/                  # GKE cluster + IAM provisioning
│   ├── bootstrap/              # One-time state bucket creation
│   ├── main.tf                 # GKE cluster and node pool
│   ├── argocd.tf               # Seeds ArgoCD via Helm
│   ├── eso.tf                  # ESO service account + Workload Identity
│   └── networking.tf           # VPC, subnet, Cloud NAT
│
└── argocd/
    ├── base/                   # Per-app Helm values and manifests
    │   ├── argocd/             # ArgoCD config, ApplicationSet, ExternalSecret
    │   ├── istio/              # Istio base + istiod Helm charts
    │   ├── istio-gateway/      # Gateway, HTTPRoute (HTTP→HTTPS redirect)
    │   ├── cert-manager/       # Helm chart + Cloudflare ExternalSecret
    │   ├── external-secrets/   # ESO Helm chart + ClusterSecretStore
    │   ├── kube-prometheus-stack/  # Prometheus + Grafana stack + dashboards
    │   ├── prometheus-operator-crds/  # CRDs (separate app, installed first)
    │   ├── kyverno/            # Kyverno Helm chart
    │   ├── kyverno-policies/   # ClusterPolicy resources (separate app)
    │   ├── kiali/              # Kiali Helm chart
    │   ├── consul/             # Consul Helm chart
    │   ├── podinfo/            # podinfo + podinfo-backend Helm charts
    │   ├── online-boutique/    # 11-service microservices demo
    │   ├── argo-rollouts/      # Argo Rollouts controller + dashboard
    │   ├── bookinfo/           # Istio bookinfo sample
    │   ├── kargo/              # Kargo install (API, controller, Dex SSO, HTTPRoute)
    │   └── kargo-podinfo/      # Kargo demo project (Warehouse + Stage for podinfo)
    │
    └── overlays/
        └── badgerops/          # Cluster-specific patches (one dir per app)
```

Each directory under `argocd/overlays/badgerops/` maps to one ArgoCD Application, generated automatically by the ApplicationSet in `argocd/base/argocd/appset.yaml`.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.14
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) authenticated (`gcloud auth application-default login`)
- A GCP project with billing enabled
- `kubectl` and `kustomize` installed locally

## Getting started

### 1. Bootstrap the Terraform state bucket

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars  # set project_id
terraform init && terraform apply
```

### 2. Provision the cluster

Create `terraform/terraform.tfvars`:

```hcl
project_id = "your-gcp-project-id"
```

Create `terraform/backend.hcl`:

```hcl
bucket = "YOUR_PROJECT_ID-tfstate"
```

Then run:

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform apply
```

This provisions the VPC, GKE cluster, node pool, and seeds ArgoCD via Helm.

### 3. Configure kubectl

```bash
gcloud container clusters get-credentials badgerops --zone us-central1-a --project YOUR_PROJECT_ID
# or use the Terraform output:
terraform output kubeconfig_command
```

### 4. Bootstrap the ArgoCD ApplicationSet

ArgoCD is seeded by Terraform but not yet self-managing. Apply the ApplicationSet once:

```bash
kubectl apply -k argocd/overlays/badgerops/argocd
```

From this point ArgoCD is fully GitOps — all apps sync automatically from `main`.

### 5. Seed required secrets in GCP Secret Manager

The following secrets must exist before the apps that use them can become healthy:

| Secret name | Used by |
|---|---|
| `argocd-github-client-secret` | ArgoCD GitHub SSO (Dex) |
| `argocd-dex-github-client-id` | ArgoCD GitHub SSO (Dex) |
| `cloudflare-api-token` | cert-manager DNS-01 challenge |
| `grafana-admin-password` | Grafana admin login |
| `grafana-admin-user` | Grafana admin login |
| `grafana-github-client-secret` | Grafana GitHub SSO |
| `kargo-admin-password-hash` | Kargo admin account (bcrypt hash) |
| `kargo-admin-token-signing-key` | Kargo JWT signing |
| `kargo-dex-github-client-id` | Kargo GitHub SSO (Dex) |
| `kargo-dex-github-client-secret` | Kargo GitHub SSO (Dex) |
| `kargo-git-token` | Kargo git push (promotion commits) |
| `kargo-git-repo-url` | Kargo git credentials |
| `kargo-git-username` | Kargo git credentials |

### 6. Configure DNS

Point `*.k8s.badgerops.io` (or your domain) to the Istio gateway LoadBalancer IP:

```bash
kubectl get svc -n istio-gateway
```

## GitOps workflow

All changes go through Git:

```bash
# Edit a base value or overlay patch
vim argocd/base/podinfo/values.yaml

# Commit and push — ArgoCD syncs automatically (every 3 minutes or on webhook)
git add . && git commit -m "update podinfo replicas" && git push
```

ArgoCD is configured with `selfHeal: true` and `prune: true`.

## Kargo promotion workflow

Kargo manages image promotions via a GitOps-native flow — it commits image tag changes to git and ArgoCD picks them up automatically.

**Concepts:**
- **Warehouse** — watches a container registry for new image tags (semver filtered)
- **Freight** — a discovered image version, ready to promote
- **Stage** — a target environment; subscribes to a Warehouse or upstream Stage
- **Promotion** — executes a sequence of steps: git-clone → kustomize-set-image → git-commit → git-push

**Demo project (`demo`):**
The `kargo-podinfo` app defines a Warehouse watching `ghcr.io/stefanprodan/podinfo` and a single Stage (`badgerops`) that targets `argocd/overlays/badgerops/podinfo/`. Promoting a version commits an `images:` override to the overlay's `kustomization.yaml` and ArgoCD syncs the new tag within ~3 minutes.

**To promote:**
1. Open `https://kargo.k8s.badgerops.io` → log in with GitHub
2. Open the `demo` project
3. Click a piece of Freight in the `podinfo` Warehouse
4. Click **Promote to Stage** → select `badgerops` → confirm

**Firewall note:** `loadBalancerSourceRanges` on the Istio gateway LB restricts access to specific IPs. The 4 office IPs are managed in git (`argocd/overlays/badgerops/istio-gateway/lb-source-ranges.yaml`). Additional IPs (e.g. home) must be added manually via `kubectl patch` — ArgoCD is configured to ignore this field so manual additions persist across syncs.

## Notes

- `terraform.tfvars` and `backend.hcl` are gitignored — never commit them
- `kustomize.buildOptions: --enable-helm` is set globally in ArgoCD so all apps can use `helmCharts:` in their kustomizations
- `ServerSideApply=true` is set globally in the ApplicationSet syncOptions — required for large CRD annotations (Kyverno, kube-prometheus-stack)
- Kyverno policies are in Audit mode (`validationFailureAction: Audit`) — they report violations but do not block deployments
- ExternalSecrets live in the kustomization of their target namespace, not in the `external-secrets` app — kustomize's `namespace:` field overrides all resource namespaces including hardcoded ones
- CRD apps (`prometheus-operator-crds`, `kyverno`) must sync before their dependent apps (`kube-prometheus-stack`, `kyverno-policies`)

## Gateway compatibility

| Gateway | Works on GKE CHANNEL_STANDARD | Reason |
|---|---|---|
| Istio (K8s Gateway API) | Yes | Uses `networking.istio.io` CRDs, not K8s experimental channel |
| GCP Native (`gke-l7-regional-external-managed`) | Yes | Built into GKE |
| Envoy Gateway | No | Requires experimental CRDs blocked by GKE admission policy |
| Consul API Gateway | No | Same experimental CRD dependency |
