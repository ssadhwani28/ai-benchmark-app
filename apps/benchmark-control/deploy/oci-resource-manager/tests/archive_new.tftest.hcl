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

run "private_versioned_archive_with_existing_vault" {
  command = apply
  variables {
    report_archive_enabled       = true
    report_archive_create_bucket = true
    report_archive_bucket_name   = "fixture-reports"
    report_archive_region        = "eu-frankfurt-1"
    report_archive_link_hours    = 24
  }
  assert {
    condition     = length(oci_kms_vault.app) == 0 && length(oci_kms_key.app) == 0 && oci_vault_secret.app[0].vault_id == var.existing_vault_ocid && oci_vault_secret.app[0].key_id == var.existing_vault_key_ocid
    error_message = "Reuse the existing Vault/key; never provision another one."
  }
  assert {
    condition     = oci_objectstorage_bucket.reports[0].access_type == "NoPublicAccess" && oci_objectstorage_bucket.reports[0].versioning == "Enabled" && oci_objectstorage_bucket.reports[0].storage_tier == "Standard"
    error_message = "New report buckets must be private, versioned and immediately readable."
  }
  assert {
    condition     = jsondecode(base64decode(oci_vault_secret.app[0].secret_content[0].content)).report_archive == output.report_archive && output.report_archive.bucket == "fixture-reports" && output.report_archive.region == "eu-frankfurt-1" && output.report_archive.link_hours == 24
    error_message = "Archive settings must reach the runtime secret, including the bucket region and expiry."
  }
  assert {
    condition     = length(oci_identity_policy.report_archive[0].statements) == 3 && alltrue([for s in oci_identity_policy.report_archive[0].statements : strcontains(s, "target.bucket.name = 'fixture-reports'") && !strcontains(s, "OBJECT_DELETE")]) && strcontains(oci_identity_policy.report_archive[0].statements[2], "PAR_MANAGE") && strcontains(oci_identity_policy.report_archive[0].statements[1], "reports/*")
    error_message = "Grant only bucket-scoped report writes/reads and PAR creation, without object deletion."
  }
}
run "disable_uploads_retains_bucket" {
  command = plan
  variables {
    report_archive_enabled       = false
    report_archive_create_bucket = true
    report_archive_bucket_name   = "fixture-reports"
    report_archive_region        = "eu-frankfurt-1"
  }
  assert {
    condition     = length(oci_objectstorage_bucket.reports) == 1 && length(oci_identity_policy.report_archive) == 0 && !output.report_archive.enabled && output.report_archive.bucket == ""
    error_message = "Disabling uploads must retain the existing managed report bucket and remove archive grants."
  }
}
