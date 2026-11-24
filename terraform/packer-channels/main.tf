terraform {
  required_providers {
    hcp = {
      source  = "hashicorp/hcp"
      version = "~> 0.110"
    }
  }
}

provider "hcp" {}

variable "production_fingerprint" {
  type        = string
  description = "Version fingerprint promoted to the production channel"
}

data "hcp_packer_version" "latest" {
  bucket_name  = "hcp-learn-base"
  channel_name = "latest"
}

resource "hcp_packer_channel" "production" {
  name        = "production"
  bucket_name = "hcp-learn-base"
}

resource "hcp_packer_channel_assignment" "production" {
  bucket_name         = hcp_packer_channel.production.bucket_name
  channel_name        = hcp_packer_channel.production.name
  version_fingerprint = var.production_fingerprint
}

data "hcp_packer_artifact" "production" {
  bucket_name   = "hcp-learn-base"
  channel_name  = hcp_packer_channel_assignment.production.channel_name
  platform      = "docker"
  region        = "docker"
}

output "latest_version" {
  value = data.hcp_packer_version.latest.name
}

output "production_image" {
  value = data.hcp_packer_artifact.production.external_identifier
}
