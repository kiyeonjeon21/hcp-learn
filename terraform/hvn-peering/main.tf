# Peer an AWS VPC with the existing HVN, then prove that a private-only EC2 instance
# can reach the Vault Dedicated *private* endpoint over the peering connection.
terraform {
  required_providers {
    hcp = { source = "hashicorp/hcp", version = "~> 0.115" }
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

variable "aws_profile" { type = string }

provider "hcp" {}

provider "aws" {
  region  = "ca-central-1"
  profile = var.aws_profile
  default_tags {
    tags = { Project = "hcp-learn" }
  }
}

data "hcp_hvn" "this" {
  hvn_id = "hvn"
}

data "hcp_vault_cluster" "this" {
  cluster_id = "vault-cluster"
}

data "aws_caller_identity" "current" {}

# --- AWS side: a small VPC with one private subnet (no internet gateway at all) ---
resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16" # must not overlap the HVN 172.25.16.0/20
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "hcp-learn-peer" }
}

resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.this.id
  cidr_block = "10.42.1.0/24"
  tags       = { Name = "hcp-learn-private" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --- Peering: HCP requests, AWS accepts ---
resource "hcp_aws_network_peering" "this" {
  hvn_id          = data.hcp_hvn.this.hvn_id
  peering_id      = "hcp-learn-peer"
  peer_vpc_id     = aws_vpc.this.id
  peer_account_id = aws_vpc.this.owner_id
  peer_vpc_region = "ca-central-1"
}

resource "aws_vpc_peering_connection_accepter" "this" {
  vpc_peering_connection_id = hcp_aws_network_peering.this.provider_peering_id
  auto_accept               = true
}

# Route both directions.
resource "hcp_hvn_route" "to_vpc" {
  hvn_link         = data.hcp_hvn.this.self_link
  hvn_route_id     = "to-hcp-learn-peer"
  destination_cidr = aws_vpc.this.cidr_block
  target_link      = hcp_aws_network_peering.this.self_link
  depends_on       = [aws_vpc_peering_connection_accepter.this]
}

resource "aws_route" "to_hvn" {
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = data.hcp_hvn.this.cidr_block
  vpc_peering_connection_id = hcp_aws_network_peering.this.provider_peering_id
  depends_on                = [aws_vpc_peering_connection_accepter.this]
}

# --- Probe instance: no public IP, no inbound rules. Result goes to the serial console. ---
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "probe" {
  name   = "hcp-learn-probe"
  vpc_id = aws_vpc.this.id

  egress {
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = [data.hcp_hvn.this.cidr_block]
  }
}

locals {
  private_host = trimsuffix(trimprefix(data.hcp_vault_cluster.this.vault_private_endpoint_url, "https://"), ":8200")
}

resource "aws_instance" "probe" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.probe.id]
  associate_public_ip_address = false
  user_data_replace_on_change = true

  user_data = <<-EOT
    #!/bin/bash
    # Wait for routes to settle, then probe Vault over the peering connection.
    sleep 60
    for i in 1 2 3 4 5; do
      echo "HCPLEARN dns: $(getent hosts ${local.private_host})" > /dev/console
      out=$(curl -s -m 10 https://${local.private_host}:8200/v1/sys/health)
      echo "HCPLEARN try $i: $${out:-no response}" > /dev/console
      [ -n "$out" ] && break
      sleep 30
    done
  EOT

  tags = { Name = "hcp-learn-vault-probe" }
}

output "peering_state" { value = hcp_aws_network_peering.this.state }
output "probe_instance_id" { value = aws_instance.probe.id }
output "vault_private_host" { value = local.private_host }
