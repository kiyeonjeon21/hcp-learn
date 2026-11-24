packer {
  required_plugins {
    docker = {
      source  = "github.com/hashicorp/docker"
      version = "~> 1.1"
    }
  }
}

variable "version_label" {
  type    = string
  default = "v1"
}

source "docker" "ubuntu" {
  image  = "ubuntu:24.04"
  commit = true
  changes = [
    "LABEL org.hcp-learn.version=${var.version_label}",
    "CMD [\"nginx\", \"-g\", \"daemon off;\"]",
  ]
}

build {
  name = "hcp-learn-base"

  hcp_packer_registry {
    bucket_name = "hcp-learn-base"
    description = "Ubuntu 24.04 + nginx, built locally with the docker builder"
    bucket_labels = {
      os    = "ubuntu"
      owner = "hcp-learn"
    }
    build_labels = {
      version = var.version_label
      "build-time" = timestamp()
    }
  }

  sources = ["source.docker.ubuntu"]

  provisioner "shell" {
    inline = [
      "apt-get update -qq",
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null",
      "echo 'hello from hcp-learn ${var.version_label}' > /var/www/html/index.html",
    ]
  }

  # Generate an SBOM inside the image with syft and upload it to HCP Packer.
  provisioner "shell" {
    inline = [
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates >/dev/null",
      "curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin >/dev/null",
      "/usr/local/bin/syft scan dir:/ --exclude ./proc --exclude ./sys -o spdx-json=/tmp/sbom.spdx.json -q",
      "rm /usr/local/bin/syft",
    ]
  }

  provisioner "hcp-sbom" {
    source = "/tmp/sbom.spdx.json"
    sbom_name = "base-os"
  }

  post-processor "docker-tag" {
    repository = "hcp-learn/base"
    tags       = [var.version_label]
  }
}
