variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "allowed_ip" {
  description = "Your public IP in CIDR notation (e.g. 1.2.3.4/32)"
  type        = string
}
