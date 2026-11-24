terraform {
  required_providers {
    boundary = { source = "hashicorp/boundary", version = "~> 1.2" }
  }
}

variable "addr" { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "password_auth_method_id" { type = string }
variable "target_passwords" {
  description = "Passwords for the local docker targets and the demo dev user"
  type = object({
    postgres = string
    ssh      = string
    dev_user = string
  })
  sensitive = true
}

variable "worker_token" {
  type      = string
  sensitive = true
}

provider "boundary" {
  addr                   = var.addr
  auth_method_id         = var.password_auth_method_id
  auth_method_login_name = "admin"
  auth_method_password   = var.admin_password
}

# --- Worker: register the self-managed worker running on the laptop (worker-led) ---
resource "boundary_worker" "laptop" {
  scope_id                    = "global"
  name                        = "laptop-worker"
  description                 = "Self-managed worker on my laptop, reaches docker containers on 127.0.0.1"
  worker_generated_auth_token = var.worker_token
}

# --- Scopes: global -> org -> project ---
resource "boundary_scope" "org" {
  scope_id                 = "global"
  name                     = "hcp-learn"
  auto_create_admin_role   = true
  auto_create_default_role = true
}

resource "boundary_scope" "project" {
  scope_id               = boundary_scope.org.id
  name                   = "local-docker"
  auto_create_admin_role = true
}

# --- Hosts ---
resource "boundary_host_catalog_static" "local" {
  scope_id = boundary_scope.project.id
  name     = "laptop-docker"
}

resource "boundary_host_static" "localhost" {
  host_catalog_id = boundary_host_catalog_static.local.id
  name            = "localhost"
  address         = "127.0.0.1"
}

resource "boundary_host_set_static" "local" {
  host_catalog_id = boundary_host_catalog_static.local.id
  name            = "laptop-docker"
  host_ids        = [boundary_host_static.localhost.id]
}

# --- Credentials (static store, brokered or injected by Boundary) ---
resource "boundary_credential_store_static" "this" {
  scope_id = boundary_scope.project.id
  name     = "static"
}

resource "boundary_credential_username_password" "pg" {
  credential_store_id = boundary_credential_store_static.this.id
  name                = "postgres-superuser"
  username            = "postgres"
  password            = var.target_passwords.postgres
}

resource "boundary_credential_username_password" "ssh" {
  credential_store_id = boundary_credential_store_static.this.id
  name                = "ssh-demo"
  username            = "demo"
  password            = var.target_passwords.ssh
}

# --- Targets: both pinned to the laptop worker via worker filters ---
resource "boundary_target" "postgres" {
  scope_id                       = boundary_scope.project.id
  name                           = "postgres"
  type                           = "tcp"
  default_port                   = 15432
  host_source_ids                = [boundary_host_set_static.local.id]
  ingress_worker_filter          = "\"laptop\" in \"/tags/type\""
  egress_worker_filter           = "\"laptop\" in \"/tags/type\""
  brokered_credential_source_ids = [boundary_credential_username_password.pg.id]
  session_max_seconds            = 3600
}

resource "boundary_target" "ssh" {
  scope_id                                   = boundary_scope.project.id
  name                                       = "ssh"
  type                                       = "ssh"
  default_port                               = 12222
  host_source_ids                            = [boundary_host_set_static.local.id]
  ingress_worker_filter                      = "\"laptop\" in \"/tags/type\""
  egress_worker_filter                       = "\"laptop\" in \"/tags/type\""
  injected_application_credential_source_ids = [boundary_credential_username_password.ssh.id]
  enable_session_recording                   = false
}

# --- A non-admin user who can only connect to the postgres target ---
resource "boundary_account_password" "dev" {
  auth_method_id = var.password_auth_method_id
  login_name     = "dev"
  password       = var.target_passwords.dev_user
}

resource "boundary_user" "dev" {
  scope_id    = "global"
  name        = "dev"
  account_ids = [boundary_account_password.dev.id]
}

resource "boundary_role" "dev_postgres_only" {
  scope_id        = boundary_scope.org.id
  grant_scope_ids = [boundary_scope.project.id]
  name            = "dev-postgres-only"
  principal_ids   = [boundary_user.dev.id]
  grant_strings = [
    "ids=${boundary_target.postgres.id};actions=read,authorize-session",
    "ids=*;type=target;actions=list,no-op",
    "ids=*;type=session;actions=list,read:self,cancel:self",
  ]
}

output "postgres_target_id" { value = boundary_target.postgres.id }
output "ssh_target_id" { value = boundary_target.ssh.id }
output "org_id" { value = boundary_scope.org.id }
