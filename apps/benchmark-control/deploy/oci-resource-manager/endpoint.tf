# Establish the endpoint before generating the IAM client, TLS certificate and
# configuration volume. Backends are attached after the container exists.
resource "oci_network_load_balancer_network_load_balancer" "app" {
  compartment_id                 = var.compartment_ocid
  display_name                   = "${var.name}-${random_id.suffix.hex}"
  subnet_id                      = data.oci_core_subnet.existing.id
  is_private                     = false
  is_preserve_source_destination = false
  network_security_group_ids     = [oci_core_network_security_group.frontend.id]
}
locals {
  public_ip  = one([for address in oci_network_load_balancer_network_load_balancer.app.ip_addresses : address.ip_address if address.is_public])
  public_url = "https://${local.public_ip}"
}
resource "oci_network_load_balancer_backend_set" "app" {
  name                     = "benchmark-https"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.app.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false
  health_checker {
    protocol    = "HTTPS"
    port        = 443
    url_path    = "/api/health"
    return_code = 200
  }
}
resource "oci_network_load_balancer_backend" "app" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.app.id
  backend_set_name         = oci_network_load_balancer_backend_set.app.name
  ip_address               = data.oci_core_vnic.app.private_ip_address
  port                     = 443
  weight                   = 1
}
resource "oci_network_load_balancer_listener" "https" {
  name                     = "https"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.app.id
  default_backend_set_name = oci_network_load_balancer_backend_set.app.name
  protocol                 = "TCP"
  port                     = 443
}
resource "oci_core_network_security_group" "frontend" {
  compartment_id = var.compartment_ocid
  vcn_id         = data.oci_core_vcn.existing.id
  display_name   = "${var.name}-public-https"
  lifecycle {
    precondition {
      condition     = length(local.allowed_client_cidrs) > 0
      error_message = "Supply at least one allowed HTTPS client IPv4 CIDR in the text field or legacy list."
    }
  }
}
resource "oci_core_network_security_group_security_rule" "backend_https" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.frontend.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}
resource "oci_core_network_security_group_security_rule" "frontend_egress" {
  network_security_group_id = oci_core_network_security_group.frontend.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.app.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}
output "network_load_balancer_ocid" { value = oci_network_load_balancer_network_load_balancer.app.id }
output "frontend_network_security_group_ocid" { value = oci_core_network_security_group.frontend.id }
