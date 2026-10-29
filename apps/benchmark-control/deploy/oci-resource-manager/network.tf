locals {
  allowed_client_cidrs   = toset(concat(var.allowed_client_cidrs, compact([for value in regexall("[^,\\r\\n]+", var.allowed_client_cidrs_text) : trimspace(value)])))
  benchmark_target_cidrs = toset(concat(var.benchmark_target_cidrs, compact([for value in regexall("[^,\\r\\n]+", var.benchmark_target_cidrs_text) : trimspace(value)])))
}
# Existing network is referenced only: no shared routes/security lists are modified.
data "oci_core_vcn" "existing" { vcn_id = var.vcn_ocid }
data "oci_core_subnet" "existing" { subnet_id = var.subnet_ocid }
resource "oci_core_network_security_group" "app" {
  compartment_id = var.compartment_ocid
  vcn_id         = data.oci_core_vcn.existing.id
  display_name   = "${var.name}-https"
  lifecycle {
    precondition {
      condition     = data.oci_core_subnet.existing.vcn_id == var.vcn_ocid && !data.oci_core_subnet.existing.prohibit_public_ip_on_vnic && (try(data.oci_core_subnet.existing.availability_domain, null) == null || try(data.oci_core_subnet.existing.availability_domain, "") == "" || data.oci_core_subnet.existing.availability_domain == var.availability_domain)
      error_message = "The existing subnet must belong to the selected VCN, permit public IPs, and be regional or match the selected AD."
    }
  }
}
resource "oci_core_network_security_group_security_rule" "https" {
  for_each                  = local.allowed_client_cidrs
  network_security_group_id = oci_core_network_security_group.frontend.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}
resource "oci_core_network_security_group_security_rule" "https_egress" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}
resource "oci_core_network_security_group_security_rule" "dns" {
  for_each                  = toset(["6", "17"])
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "EGRESS"
  protocol                  = each.value
  destination               = "169.254.169.254/32"
  destination_type          = "CIDR_BLOCK"
  dynamic "tcp_options" {
    for_each = each.value == "6" ? [1] : []
    content {
      destination_port_range {
        min = 53
        max = 53
      }
    }
  }
  dynamic "udp_options" {
    for_each = each.value == "17" ? [1] : []
    content {
      destination_port_range {
        min = 53
        max = 53
      }
    }
  }
}
resource "oci_core_network_security_group_security_rule" "benchmark_ssh" {
  for_each                  = local.benchmark_target_cidrs
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = each.value
  destination_type          = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}
