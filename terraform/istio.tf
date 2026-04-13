resource "helm_release" "istio_base" {
  name             = "istio-base"
  namespace        = "istio-system"
  create_namespace = true

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = "1.24.3"
}

resource "helm_release" "istiod" {
  name      = "istiod"
  namespace = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = "1.24.3"

  values = [yamlencode({
    pilot = {
      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }
    }
  })]

  depends_on = [helm_release.istio_base]
}
