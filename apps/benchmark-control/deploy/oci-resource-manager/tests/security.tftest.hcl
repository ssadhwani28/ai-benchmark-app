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
mock_provider "oci" { alias = "archive" }
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
run "authenticated_container_graph" {
  command = apply
  assert {
    condition     = output.application_url == "https://192.0.2.10" && contains(oci_identity_domains_app.benchmark.redirect_uris, output.callback_url)
    error_message = "The assigned public IP must drive the app origin and IAM callback."
  }
  assert {
    condition     = oci_container_instances_container_instance.app.vnics[0].subnet_id == var.subnet_ocid && !oci_container_instances_container_instance.app.containers[0].is_resource_principal_disabled
    error_message = "Use the existing subnet and enable the Container Instance resource principal."
  }
  assert {
    condition     = oci_identity_domains_app.benchmark.active && oci_identity_domains_app.benchmark.client_type == "confidential" && toset(oci_identity_domains_app.benchmark.allowed_grants) == toset(["authorization_code"]) && (oci_identity_domains_app.benchmark.login_page_url == null || oci_identity_domains_app.benchmark.login_page_url == "") && oci_identity_domains_app.benchmark.signon_policy[0].value == var.iam_mfa_signon_policy_id
    error_message = "IAM must use an active confidential code client, default login page and selected MFA policy."
  }
  assert {
    condition     = jsondecode(base64decode(oci_vault_secret.app[0].secret_content[0].content)).oidc_client_id == "generated-client-id" && jsondecode(base64decode(oci_vault_secret.app[0].secret_content[0].content)).public_url == output.application_url
    error_message = "Vault configuration must use the generated IAM client ID and actual app URL."
  }
  assert {
    condition     = contains(tls_self_signed_cert.app.ip_addresses, "192.0.2.10") && length(oci_identity_policy.app[0].statements) == 1 && length(oci_identity_policy.benchmark_workloads) == 0
    error_message = "TLS must cover the public IP; workload permissions must be off by default."
  }
}
run "private_registry" {
  command = plan
  variables {
    registry_username = "namespace/domain/user"
    registry_password = "fixture-token"
  }
  assert {
    condition     = oci_container_instances_container_instance.app.image_pull_secrets[0].username == base64encode(var.registry_username) && oci_container_instances_container_instance.app.image_pull_secrets[0].password == base64encode(var.registry_password)
    error_message = "OCI requires base64-encoded registry credentials."
  }
}
run "scoped_workload_permissions" {
  command = plan
  variables {
    benchmark_compartment_ocids         = jsonencode(["ocid1.compartment.oc1..workloads"])
    benchmark_network_compartment_ocids = jsonencode(["ocid1.compartment.oc1..network"])
  }
  assert {
    condition     = length(oci_identity_policy.benchmark_workloads) == 1 && length(oci_identity_policy.benchmark_workloads[0].statements) == 4
    error_message = "Optional benchmark permissions must be explicitly scoped."
  }
}
run "reject_unrestricted_ingress" {
  command = plan
  variables { allowed_client_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.allowed_client_cidrs]
}
run "reject_empty_allowlist" {
  command = plan
  variables {
    oidc_authorization_mode = "subject_allowlist"
    allowed_subjects        = []
  }
  expect_failures = [oci_identity_domains_app.benchmark]
}
run "reject_mutable_image" {
  command = plan
  variables { app_image_url = "registry.example.test/team/app:latest" }
  expect_failures = [var.app_image_url]
}
run "reject_incomplete_registry_credentials" {
  command = plan
  variables { registry_username = "namespace/user" }
  expect_failures = [oci_container_instances_container_instance.app]
}
run "reject_wrong_network" {
  command = plan
  override_data {
    target = data.oci_core_subnet.existing
    values = { vcn_id = "ocid1.vcn.oc1.other", prohibit_public_ip_on_vnic = false }
  }
  expect_failures = [oci_core_network_security_group.app]
}
run "reject_private_subnet" {
  command = plan
  override_data {
    target = data.oci_core_subnet.existing
    values = { vcn_id = "ocid1.vcn.oc1.test", prohibit_public_ip_on_vnic = true }
  }
  expect_failures = [oci_core_network_security_group.app]
}

run "reject_empty_mfa_policy" {
  command = plan
  variables { iam_mfa_signon_policy_id = "" }
  expect_failures = [var.iam_mfa_signon_policy_id]
}
run "reject_missing_workload_network_scope" {
  command = plan
  variables { benchmark_compartment_ocids = jsonencode(["ocid1.compartment.oc1..workloads"]) }
  expect_failures = [oci_identity_policy.benchmark_workloads]
}
