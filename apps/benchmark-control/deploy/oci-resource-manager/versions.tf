terraform {
  required_version = ">= 1.5.0, < 2.0.0"
  required_providers {
    oci    = { source = "oracle/oci", version = "~> 7.0" }
    random = { source = "hashicorp/random", version = "~> 3.7" }
    tls    = { source = "hashicorp/tls", version = "~> 4.1" }
  }
}
provider "oci" {
  region = var.region
}
