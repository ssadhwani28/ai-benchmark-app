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
  mock_data "oci_kms_encrypted_data" { defaults = { ciphertext = "fixture-kms-ciphertext" } }
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


run "encrypted_runtime_without_new_vault" {
  command = apply
  variables {
    runtime_config_delivery      = "kms_object_storage"
    report_archive_enabled       = true
    report_archive_create_bucket = true
    report_archive_bucket_name   = "fixture-encrypted-runtime"
  }
  assert {
    condition     = length(oci_kms_vault.app) == 0 && length(oci_kms_key.app) == 0 && oci_objectstorage_object.runtime[0].content == "fixture-kms-ciphertext" && oci_objectstorage_object.runtime[0].content_type == "application/octet-stream"
    error_message = "Store only KMS ciphertext in a private bucket; never create another Vault/key."
  }
  assert {
    condition     = strcontains(oci_identity_policy.runtime_decrypt[0].statements[0], "KEY_DECRYPT") && strcontains(oci_identity_policy.runtime_decrypt[0].statements[0], var.existing_vault_key_ocid) && !strcontains(oci_identity_policy.runtime_decrypt[0].statements[0], "KEY_ENCRYPT") && strcontains(oci_identity_policy.runtime_object[0].statements[0], local.runtime_config_object)
    error_message = "Grant only existing-key decryption and exact encrypted-object reads."
  }
  assert {
    condition     = oci_container_instances_container_instance.app.containers[0].environment_variables["BENCHMARK_CONFIG_SOURCE"] == "kms_object_storage" && oci_container_instances_container_instance.app.containers[0].environment_variables["BENCHMARK_KMS_KEY_ID"] == var.existing_vault_key_ocid
    error_message = "The bootstrap must use the selected encrypted delivery mode and existing key."
  }
}

run "unchanged_settings_retain_ciphertext" {
  command = plan
  variables {
    runtime_config_delivery      = "kms_object_storage"
    report_archive_enabled       = true
    report_archive_create_bucket = true
    report_archive_bucket_name   = "fixture-encrypted-runtime"
  }
  override_data {
    target = data.oci_kms_encrypted_data.runtime[0]
    values = { ciphertext = "random-new-encryption-of-same-settings" }
  }
  assert {
    condition     = oci_objectstorage_object.runtime[0].content == "fixture-kms-ciphertext"
    error_message = "Random KMS nonce changes must not rewrite an unchanged runtime configuration."
  }
}
run "changed_settings_replace_envelope" {
  command = apply
  variables {
    runtime_config_delivery      = "kms_object_storage"
    report_archive_enabled       = true
    report_archive_create_bucket = true
    report_archive_bucket_name   = "fixture-encrypted-runtime"
    report_archive_link_hours    = 24
  }
  override_data {
    target = data.oci_kms_encrypted_data.runtime[0]
    values = { ciphertext = "new-settings-ciphertext" }
  }
  assert {
    condition     = oci_objectstorage_object.runtime[0].content == "new-settings-ciphertext"
    error_message = "A real configuration change must replace the encrypted envelope."
  }
}
