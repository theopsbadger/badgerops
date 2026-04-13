# badgerops

A GKE-based homelab cluster running ArgoCD, Consul, and Istio on GCP free tier.

## Stack

- **GKE Standard** — zonal cluster (us-central1-a), e2-small nodes, private networking with Cloud NAT
- **ArgoCD** — deployed via Helm, exposed via Istio ingress
- **Consul** — service catalog sync only (no sidecar injection)
- **Istio** — north-south ingress using the Kubernetes Gateway API

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.14
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) authenticated (`gcloud auth application-default login`)
- A GCP project with billing enabled
- `kubectl` configured after cluster creation

## Getting started

### 1. Bootstrap the Terraform state bucket

The state bucket must exist before running the main Terraform config.

Create `terraform/bootstrap/terraform.tfvars`:

```hcl
project_id = "your-gcp-project-id"
```

Then run:

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

### 2. Configure the main Terraform workspace

Create `terraform/terraform.tfvars`:

```hcl
project_id = "your-gcp-project-id"
allowed_ip = "your-public-ip/32"  # restricts ArgoCD access to your IP only
```

To find your public IP:

```bash
curl -s ifconfig.me
```

### 3. Deploy the cluster

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

This provisions:
- VPC, subnet, Cloud NAT
- GKE cluster with the `sett` node pool
- ArgoCD, Consul, and Istio via Helm

### 4. Configure kubectl

```bash
gcloud container clusters get-credentials badgerops --zone us-central1-a --project your-gcp-project-id
```

Or use the Terraform output:

```bash
terraform output kubeconfig_command
```

### 5. Deploy the Istio gateway

```bash
kubectl apply -f argocd/infra/istio_gateway/
```

Then restrict access to your IP:

```bash
kubectl patch service istio-gateway-istio -n istio-gateway \
  --type merge \
  -p '{"spec":{"loadBalancerSourceRanges":["your-public-ip/32"]}}'
```

Get the gateway IP:

```bash
kubectl get gateway istio-gateway -n istio-gateway -o jsonpath='{.status.addresses[0].value}'
```

ArgoCD will be accessible at `http://<gateway-ip>`.

### 6. Get the ArgoCD admin password

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

## Notes

- The `terraform.tfvars` files are gitignored — never commit them
- Consul connect injection is disabled; Consul is used for service catalog sync only
- The Istio gateway uses the Kubernetes Gateway API (`gatewayClassName: istio`) with auto-provisioned LoadBalancer
- GKE `CHANNEL_STANDARD` is used for the Gateway API — experimental CRDs are blocked by GKE admission policy on this cluster configuration. See [gateway compatibility notes](#gateway-compatibility) below

## Gateway compatibility

| Gateway | Works on GKE CHANNEL_STANDARD | Reason |
|---|---|---|
| Istio (K8s Gateway API) | Yes | Uses `networking.istio.io` CRDs, not K8s experimental channel |
| GCP Native (`gke-l7-regional-external-managed`) | Yes | Built into GKE |
| Envoy Gateway | No | Requires experimental CRDs blocked by GKE admission policy |
| Consul API Gateway | No | Same experimental CRD dependency |
| Consul IngressGateway | Partially | Catalog-synced non-mesh services get no xDS endpoints |
