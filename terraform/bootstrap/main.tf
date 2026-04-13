terraform {
  required_version = ">= 1.14"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.18"
    }
  }
}

provider "google" {
  project = local.project_id
  region  = local.region
}

resource "google_storage_bucket" "tfstate" {
  name          = "${local.project_id}-tfstate"
  location      = local.region
  force_destroy = false

  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true
}
