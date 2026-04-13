resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "primary" {
  name                    = local.cluster_name
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "primary" {
  name          = local.cluster_name
  network       = google_compute_network.primary.id
  region        = local.region
  ip_cidr_range = "10.0.0.0/24"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/20"
  }
}

resource "google_compute_router" "primary" {
  name    = local.cluster_name
  network = google_compute_network.primary.id
  region  = local.region
}

resource "google_compute_router_nat" "primary" {
  name                               = local.cluster_name
  router                             = google_compute_router.primary.name
  region                             = local.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_subnetwork" "proxy_only" {
  name          = "${local.cluster_name}-proxy-only"
  network       = google_compute_network.primary.id
  region        = local.region
  ip_cidr_range = "10.3.0.0/24"
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}
