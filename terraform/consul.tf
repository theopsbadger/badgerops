resource "helm_release" "consul" {
  name             = "consul"
  namespace        = "consul"
  create_namespace = true

  repository = "https://helm.releases.hashicorp.com"
  chart      = "consul"
  version    = "1.9.6"

  values = [
    yamlencode({
      global = {
        name = "consul"
      }
      syncCatalog = {
        enabled = true
      }
      connectInject = {
        enabled = false
        apiGateway = {
          manageExternalCRDs = false
        }
      }
    })
  ]

  depends_on = [helm_release.argocd]
}
