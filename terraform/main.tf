provider "google" {
  project = local.project_id
  region  = local.region
}

resource "google_project_service" "container" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE Node Service Account"
}

resource "google_project_iam_member" "nodes_default_node_sa" {
  project = local.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "primary" {
  name     = local.cluster_name
  location = local.zone

  network    = google_compute_network.primary.id
  subnetwork = google_compute_subnetwork.primary.id

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "all"
    }
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  workload_identity_config {
    workload_pool = "${local.project_id}.svc.id.goog"
  }

  depends_on = [google_project_service.container]
}

resource "google_container_node_pool" "primary" {
  name     = local.node_pool_name
  cluster  = google_container_cluster.primary.name
  location = local.zone

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type    = "e2-medium"
    disk_size_gb    = 20
    disk_type       = "pd-standard"
    service_account = google_service_account.nodes.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}
