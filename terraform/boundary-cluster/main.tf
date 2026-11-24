terraform {
  required_providers {
    hcp    = { source = "hashicorp/hcp", version = "~> 0.115" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "hcp" {}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "hcp_boundary_cluster" "this" {
  cluster_id = "hcp-learn-boundary"
  username   = "admin"
  password   = random_password.admin.result
  tier       = "Standard"
}

output "cluster_url" {
  value = hcp_boundary_cluster.this.cluster_url
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}
