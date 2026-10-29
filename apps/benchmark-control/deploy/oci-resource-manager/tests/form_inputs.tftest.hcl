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
run "text_fields_accept_newlines_commas_and_deduplicate" {
  command = apply
  variables {
    allowed_client_cidrs        = []
    allowed_client_cidrs_text   = " 192.0.2.24/32\n198.51.100.0/24, 192.0.2.24/32\r\n"
    benchmark_target_cidrs_text = "10.0.1.0/24,10.0.2.10/32"
  }
  assert {
    condition     = toset(keys(oci_core_network_security_group_security_rule.https)) == toset(["192.0.2.24/32", "198.51.100.0/24"]) && toset(keys(oci_core_network_security_group_security_rule.benchmark_ssh)) == toset(["10.0.1.0/24", "10.0.2.10/32"])
    error_message = "Text fields must produce the expected source and SSH rules without duplicates."
  }
  assert {
    condition     = length(oci_identity_policy.benchmark_workloads) == 0
    error_message = "SSH target networks alone must not grant VM provisioning permissions."
  }
}
run "legacy_and_text_sources_are_combined" {
  command = plan
  variables {
    allowed_client_cidrs      = ["192.0.2.0/24"]
    allowed_client_cidrs_text = "198.51.100.0/24"
  }
  assert {
    condition     = length(oci_core_network_security_group_security_rule.https) == 2 && length(oci_core_network_security_group_security_rule.benchmark_ssh) == 0
    error_message = "Preserve legacy client lists; SSH remains optional and off by default."
  }
}
run "missing_https_sources_rejected" {
  command = plan
  variables {
    allowed_client_cidrs      = []
    allowed_client_cidrs_text = " ,\n "
  }
  expect_failures = [oci_core_network_security_group.frontend]
}
run "unrestricted_text_sources_rejected" {
  command = plan
  variables { allowed_client_cidrs_text = "0.0.0.0/0" }
  expect_failures = [var.allowed_client_cidrs_text]
}
run "invalid_text_sources_rejected" {
  command = plan
  variables { allowed_client_cidrs_text = "192.0.2.24" }
  expect_failures = [var.allowed_client_cidrs_text]
}
run "unrestricted_ssh_targets_rejected" {
  command = plan
  variables { benchmark_target_cidrs_text = "0.0.0.0/0" }
  expect_failures = [var.benchmark_target_cidrs_text]
}
run "wrong_subnet_ad_rejected" {
  command = plan
  override_data {
    target = data.oci_core_subnet.existing
    values = { availability_domain = "other:US-ASHBURN-AD-2", vcn_id = "ocid1.vcn.oc1.test", prohibit_public_ip_on_vnic = false }
  }
  expect_failures = [oci_core_network_security_group.app]
}
run "matching_subnet_ad_accepted" {
  command = plan
  override_data {
    target = data.oci_core_subnet.existing
    values = { availability_domain = "fixture:US-ASHBURN-AD-1", vcn_id = "ocid1.vcn.oc1.test", prohibit_public_ip_on_vnic = false }
  }
}
run "saved_blank_vm_inputs_disable_permissions" {
  command = plan
  variables {
    benchmark_compartment_ocids         = ""
    benchmark_network_compartment_ocids = ""
  }
  assert {
    condition     = length(oci_identity_policy.benchmark_workloads) == 0
    error_message = "Saved empty strings must parse successfully and grant no VM permissions."
  }
}
run "saved_json_empty_vm_inputs_disable_permissions" {
  command = plan
  variables {
    benchmark_compartment_ocids         = "[]"
    benchmark_network_compartment_ocids = "[]"
  }
  assert {
    condition     = length(oci_identity_policy.benchmark_workloads) == 0
    error_message = "Saved JSON empty lists must remain accepted with no privileges."
  }
}
run "text_vm_compartments_are_scoped" {
  command = plan
  variables {
    benchmark_compartment_ocids         = "ocid1.compartment.oc1..workloads,\nocid1.compartment.oc1..workloads"
    benchmark_network_compartment_ocids = "ocid1.compartment.oc1..network"
  }
  assert {
    condition     = length(oci_identity_policy.benchmark_workloads) == 1 && length(oci_identity_policy.benchmark_workloads[0].statements) == 4
    error_message = "Text inputs must deduplicate compartments and retain explicit VM/network scope."
  }
}
run "reject_invalid_vm_compartment_text" {
  command = plan
  variables { benchmark_compartment_ocids = "not-a-compartment" }
  expect_failures = [var.benchmark_compartment_ocids]
}
