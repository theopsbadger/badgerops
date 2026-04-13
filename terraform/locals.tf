locals {
  project_id     = var.project_id
  region         = "us-central1"
  zone           = "us-central1-a"
  cluster_name   = "badgerops"
  node_pool_name = "sett"
  allowed_ip     = var.allowed_ip
}
