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
  mock_data "oci_objectstorage_bucket" { defaults = { access_type = "NoPublicAccess", storage_tier = "Standard", compartment_id = "ocid1.compartment.oc1..fixture" } }
}
mock_provider "random" {}
mock_provider "tls" {}
variables {
  runtime_config_delivery  = "vault"
  existing_vault_ocid      = "ocid1.vault.oc1.test"
  existing_vault_key_ocid  = "ocid1.key.oc1.test"
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

run "disabled_has_no_storage_or_archive_grants" {
  command = plan
  assert {
    condition     = length(oci_objectstorage_bucket.reports) == 0 && length(data.oci_objectstorage_namespace.archive) == 0 && length(oci_identity_policy.report_archive) == 0 && length(oci_kms_vault.app) == 0 && length(oci_kms_key.app) == 0
    error_message = "Disabled archiving must not create buckets, policies, Vaults or keys."
  }
}
run "existing_private_bucket" {
  command = plan
  variables {
    report_archive_enabled     = true
    report_archive_bucket_name = "existing-reports"
  }
  assert {
    condition     = length(oci_objectstorage_bucket.reports) == 0 && length(data.oci_objectstorage_bucket.reports) == 1 && output.report_archive.bucket == "existing-reports" && length(oci_identity_policy.report_archive) == 1
    error_message = "Existing buckets must be referenced, without taking ownership or creating replacements."
  }
}
run "missing_bucket_name" {
  command = plan
  variables { report_archive_enabled = true }
  expect_failures = [data.oci_objectstorage_bucket.reports]
}
run "public_bucket_rejected" {
  command = plan
  variables {
    report_archive_enabled     = true
    report_archive_bucket_name = "existing-reports"
  }
  override_data {
    target = data.oci_objectstorage_bucket.reports[0]
    values = { access_type = "ObjectRead", storage_tier = "Standard", compartment_id = "ocid1.compartment.oc1..fixture" }
  }
  expect_failures = [data.oci_objectstorage_bucket.reports]
}
run "cold_storage_rejected" {
  command = plan
  variables {
    report_archive_enabled     = true
    report_archive_bucket_name = "existing-reports"
  }
  override_data {
    target = data.oci_objectstorage_bucket.reports[0]
    values = { access_type = "NoPublicAccess", storage_tier = "Archive", compartment_id = "ocid1.compartment.oc1..fixture" }
  }
  expect_failures = [data.oci_objectstorage_bucket.reports]
}
run "wrong_compartment_rejected" {
  command = plan
  variables {
    report_archive_enabled     = true
    report_archive_bucket_name = "existing-reports"
  }
  override_data {
    target = data.oci_objectstorage_bucket.reports[0]
    values = { access_type = "NoPublicAccess", storage_tier = "Standard", compartment_id = "ocid1.compartment.oc1..other" }
  }
  expect_failures = [data.oci_objectstorage_bucket.reports]
}
run "invalid_link_hours" {
  command = plan
  variables { report_archive_link_hours = 0 }
  expect_failures = [var.report_archive_link_hours]
}
run "unsafe_bucket_name" {
  command = plan
  variables { report_archive_bucket_name = "bad'policy" }
  expect_failures = [var.report_archive_bucket_name]
}
run "disabled_key_rejected" {
  command = plan
  override_data {
    target = data.oci_kms_key.existing[0]
    values = { state = "DISABLED", key_shape = [{ algorithm = "AES", length = 32 }] }
  }
  expect_failures = [data.oci_kms_key.existing]
}

run "pending_deletion_vault_rejected" {
  command = plan
  override_data {
    target = data.oci_kms_vault.existing[0]
    values = { state = "PENDING_DELETION" }
  }
  expect_failures = [data.oci_kms_vault.existing]
}
