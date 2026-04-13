data "google_client_config" "default" {}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.5.0"

  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = true
        }
        cm = {
          "kustomize.buildOptions" = "--enable-helm"
        }
      }
      repoServer = {
        livenessProbe = {
          initialDelaySeconds = 30
        }
        readinessProbe = {
          initialDelaySeconds = 30
        }
      }
      server = {}
    })
  ]
}
