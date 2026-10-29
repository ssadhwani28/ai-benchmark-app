# Terraform >=1.7: mocked providers, no cloud requests.
mock_provider "oci" {
  mock_resource "oci_network_load_balancer_network_load_balancer" { defaults = { ip_addresses = [{ ip_address = "192.0.2.10", is_public = true, ip_version = "IPV4" }] } }
  mock_data "oci_core_vcn" { defaults = { id = "ocid1.vcn.oc1.test" } }
  mock_data "oci_core_subnet" {
    defaults = {
      id                         = "ocid1.subnet.oc1.test"
      vcn_id                     = "ocid1.vcn.oc1.test"
      availability_domain        = ""
      prohibit_public_ip_on_vnic = false
    }
  }
  mock_data "oci_core_vnic" { defaults = { public_ip_address = "192.0.2.10" } }
  mock_data "oci_kms_vault" { defaults = { id = "ocid1.vault.oc1.test", management_endpoint = "https://kms.example.test", crypto_endpoint = "https://crypto.example.test", state = "ACTIVE" } }
  mock_data "oci_kms_key" { defaults = { id = "ocid1.key.oc1.test", compartment_id = "ocid1.compartment.oc1..fixture", state = "ENABLED", key_shape = [{ algorithm = "AES", length = 32 }] } }
  mock_resource "oci_identity_domains_app" { defaults = { name = "generated-client-id", client_secret = "generated-secret", login_page_url = "" } }
}
mock_provider "oci" {
  alias = "archive"
  mock_data "oci_objectstorage_namespace" { defaults = { namespace = "fixture-namespace" } }
}
mock_provider "random" {}
mock_provider "tls" {}
variables {
  tenancy_ocid             = "ocid1.tenancy.oc1..fixture"
  compartment_ocid         = "ocid1.compartment.oc1..fixture"
  region                   = "us-ashburn-1"
  availability_domain      = "fixture:US-ASHBURN-AD-1"
  vcn_ocid                 = "ocid1.vcn.oc1.test"
  subnet_ocid              = "ocid1.subnet.oc1.test"
  identity_domain_url      = "https://iam.example.test"
  oidc_issuer              = "https://identity.oraclecloud.com/"
  iam_mfa_signon_policy_id = "fixture-mfa-policy"
  allowed_subjects         = ["approved-operator"]
  allowed_client_cidrs     = ["192.0.2.0/24"]
  app_image_url            = "registry.example.test/team/benchmark@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
run "private_volume_without_vault" {
  command = apply
  assert {
    condition     = var.runtime_config_delivery == "config_volume" && length(data.oci_kms_vault.existing) == 0 && length(data.oci_kms_key.existing) == 0 && length(oci_vault_secret.app) == 0 && length(oci_identity_policy.app) == 0 && length(oci_identity_policy.runtime_decrypt) == 0 && length(oci_objectstorage_object.runtime) == 0 && output.runtime_secret_ocid == null
    error_message = "Default private configuration delivery must not read or create Vault, key, secret or encrypted runtime resources."
  }
  assert {
    condition     = output.application_url == "https://192.0.2.10" && output.callback_url == "https://192.0.2.10/auth/callback" && contains(tls_self_signed_cert.app.ip_addresses, "192.0.2.10") && contains(oci_identity_domains_app.benchmark.redirect_uris, output.callback_url)
    error_message = "The stable frontend must drive the HTTPS 443 origin, certificate and callback before container creation."
  }
  assert {
    condition     = oci_network_load_balancer_backend.app.ip_address == data.oci_core_vnic.app.private_ip_address && oci_network_load_balancer_listener.https.port == 443 && oci_network_load_balancer_listener.https.protocol == "TCP" && oci_network_load_balancer_backend.app.port == 443 && !oci_network_load_balancer_backend_set.app.is_preserve_source
    error_message = "The public frontend must forward encrypted traffic to the container private address on 443."
  }
  assert {
    condition     = alltrue([for m in oci_container_instances_container_instance.app.containers[0].volume_mounts : m.is_read_only if m.volume_name == "private-configuration"]) && length([for m in oci_container_instances_container_instance.app.containers[0].volume_mounts : m if m.volume_name == "private-configuration" && m.mount_path == "/run/benchmark-config"]) == 1
    error_message = "Mount exactly one private read-only configuration volume."
  }
  assert {
    condition     = one([for v in oci_container_instances_container_instance.app.volumes : jsondecode(base64decode(v.configs[0].data)).oidc_client_id if v.name == "private-configuration"]) == "generated-client-id" && one([for v in oci_container_instances_container_instance.app.volumes : jsondecode(base64decode(v.configs[0].data)).public_url if v.name == "private-configuration"]) == output.application_url
    error_message = "The volume must contain the registered IAM client and actual frontend origin."
  }
  assert {
    condition     = !contains(keys(oci_container_instances_container_instance.app.containers[0].environment_variables), "BENCHMARK_VAULT_ID") && !contains(values(oci_container_instances_container_instance.app.containers[0].environment_variables), "generated-secret") && length(oci_identity_policy.benchmark_workloads) == 0
    error_message = "No Vault reference, plaintext OAuth environment secret or implicit VM privileges."
  }
  assert {
    condition     = alltrue([for r in oci_core_network_security_group_security_rule.https : r.tcp_options[0].destination_port_range[0].min == 443 && r.network_security_group_id == oci_core_network_security_group.frontend.id]) && oci_core_network_security_group_security_rule.backend_https.source_type == "NETWORK_SECURITY_GROUP"
    error_message = "Approved clients reach frontend 443 and only the frontend NSG is granted backend access."
  }
}
run "vault_mode_requires_existing_vault" {
  command = plan
  variables { runtime_config_delivery = "vault" }
  expect_failures = [data.oci_kms_vault.existing[0]]
}
run "volume_with_report_archive" {
  command = apply
  variables {
    report_archive_enabled       = true
    report_archive_create_bucket = true
    report_archive_bucket_name   = "fixture-private-volume-reports"
  }
  assert {
    condition     = output.report_archive.enabled && length(oci_identity_policy.report_archive) == 1 && length(oci_vault_secret.app) == 0 && one([for v in oci_container_instances_container_instance.app.volumes : jsondecode(base64decode(v.configs[0].data)).report_archive.bucket if v.name == "private-configuration"]) == "fixture-private-volume-reports"
    error_message = "Archive configuration and scoped principal permissions must remain available without Vault."
  }
}
