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
run "assignment_default_without_subjects" {
  command = apply
  variables { allowed_subjects = [] }
  assert {
    condition     = var.oidc_authorization_mode == "app_assignment" && oci_identity_domains_app.benchmark.allow_access_control && oci_identity_domains_app.benchmark.signon_policy[0].value == var.iam_mfa_signon_policy_id
    error_message = "IAM must enforce app grants and the existing sign-on/MFA policy by default."
  }
  assert {
    condition     = one([for v in oci_container_instances_container_instance.app.volumes : jsondecode(base64decode(v.configs[0].data)).authorization_mode if v.name == "private-configuration"]) == "app_assignment" && one([for v in oci_container_instances_container_instance.app.volumes : length(jsondecode(base64decode(v.configs[0].data)).allowed_subjects) if v.name == "private-configuration"]) == 0
    error_message = "Assignment mode must reach runtime without requiring baked-in subjects."
  }
}
run "additional_subject_restriction" {
  command = plan
  variables { oidc_authorization_mode = "subject_allowlist" }
  assert {
    condition     = oci_identity_domains_app.benchmark.allow_access_control
    error_message = "Optional allowlists must never disable IAM app-grant enforcement."
  }
}
run "empty_additional_allowlist_rejected" {
  command = plan
  variables {
    oidc_authorization_mode = "subject_allowlist"
    allowed_subjects        = []
  }
  expect_failures = [oci_identity_domains_app.benchmark]
}
run "unknown_authorization_mode_rejected" {
  command = plan
  variables { oidc_authorization_mode = "all_tenancy_users" }
  expect_failures = [var.oidc_authorization_mode]
}
