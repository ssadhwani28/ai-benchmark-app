locals {
  benchmark_compartment_ocids         = toset(try(tolist(jsondecode(var.benchmark_compartment_ocids)), compact([for value in regexall("[^,\\r\\n]+", var.benchmark_compartment_ocids) : trimspace(value)])))
  benchmark_network_compartment_ocids = toset(try(tolist(jsondecode(var.benchmark_network_compartment_ocids)), compact([for value in regexall("[^,\\r\\n]+", var.benchmark_network_compartment_ocids) : trimspace(value)])))
}
resource "terraform_data" "identity_origin" {
  # A one-time client-registration migration enables grant enforcement through
  # creation; older OCI providers can fail full PUT updates of active clients.
  input = { origin = local.public_url, authorization_policy = "enforced_app_grants_v1" }
}
resource "oci_identity_domains_app" "benchmark" {
  idcs_endpoint   = trimsuffix(var.identity_domain_url, "/")
  display_name    = "${var.name}-${random_id.suffix.hex}"
  schemas         = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]
  active          = true
  is_oauth_client = true
  # Enforce grants as authorization: unassigned domain users cannot sign in.
  # Assignments are managed in IAM after Apply, not embedded in the volume.
  allow_access_control = true
  client_type          = "confidential"
  allowed_grants       = ["authorization_code"]
  redirect_uris        = ["${local.public_url}/auth/callback"]
  is_login_target      = true
  login_page_url       = null
  landing_page_url     = "${local.public_url}/"
  login_mechanism      = "OIDC"
  # Identity Domains adds template extension schemas; these are server-managed.
  lifecycle {
    precondition {
      condition     = var.oidc_authorization_mode != "subject_allowlist" || length(var.allowed_subjects) > 0
      error_message = "subject_allowlist mode requires at least one approved OIDC subject."
    }
    ignore_changes = [schemas]
    # Bind each replacement frontend endpoint through client creation; older
    # Identity Domains providers can fail full PUT updates of an active client.
    replace_triggered_by = [terraform_data.identity_origin]
  }
  based_on_template { value = var.iam_template_id }
  signon_policy { value = var.iam_mfa_signon_policy_id }
}
resource "random_password" "app" {
  length  = 64
  special = false
}
resource "random_id" "suffix" { byte_length = 4 }
resource "tls_private_key" "app" {
  algorithm = "RSA"
  rsa_bits  = 2048
}
resource "tls_self_signed_cert" "app" {
  private_key_pem       = tls_private_key.app.private_key_pem
  validity_period_hours = 8760
  early_renewal_hours   = 720
  ip_addresses          = [local.public_ip]
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
  subject { common_name = local.public_ip }
}
data "oci_kms_vault" "existing" {
  count    = var.runtime_config_delivery == "config_volume" ? 0 : 1
  vault_id = var.existing_vault_ocid
  lifecycle {
    precondition {
      condition     = var.existing_vault_ocid != "" && var.existing_vault_key_ocid != ""
      error_message = "Vault-based delivery requires both existing Vault and key OCIDs."
    }
    postcondition {
      condition     = self.state == "ACTIVE"
      error_message = "The existing Vault must be ACTIVE, not pending deletion or restoration."
    }
  }
}
data "oci_kms_key" "existing" {
  count               = var.runtime_config_delivery == "config_volume" ? 0 : 1
  key_id              = var.existing_vault_key_ocid
  management_endpoint = data.oci_kms_vault.existing[0].management_endpoint
  lifecycle {
    postcondition {
      condition     = self.state == "ENABLED" && self.key_shape[0].algorithm == "AES" && self.key_shape[0].length == 32
      error_message = "Select an enabled AES-256 key in the existing Vault."
    }
  }
}
# Migration guards only: never create a Vault/key. Keeping the old addresses
# prevents a previous stack's owned Vault/key being silently destroyed on upgrade.
moved {
  from = oci_kms_vault.app
  to   = oci_kms_vault.app[0]
}
moved {
  from = oci_kms_key.app
  to   = oci_kms_key.app[0]
}
resource "oci_kms_vault" "app" {
  count          = 0
  compartment_id = var.compartment_ocid
  display_name   = "legacy-vault-migration-guard"
  vault_type     = "DEFAULT"
  lifecycle { prevent_destroy = true }
}
resource "oci_kms_key" "app" {
  count               = 0
  compartment_id      = var.compartment_ocid
  display_name        = "legacy-key-migration-guard"
  management_endpoint = try(data.oci_kms_vault.existing[0].management_endpoint, "")
  key_shape {
    algorithm = "AES"
    length    = 32
  }
  lifecycle { prevent_destroy = true }
}
moved {
  from = oci_vault_secret.app
  to   = oci_vault_secret.app[0]
}
moved {
  from = oci_identity_policy.app
  to   = oci_identity_policy.app[0]
}
resource "oci_vault_secret" "app" {
  count          = var.runtime_config_delivery == "config_volume" ? 0 : 1
  depends_on     = [oci_identity_policy.report_archive]
  compartment_id = var.compartment_ocid
  vault_id       = data.oci_kms_vault.existing[0].id
  key_id         = data.oci_kms_key.existing[0].id
  secret_name    = local.runtime_secret_name
  secret_content {
    content_type = "BASE64"
    content      = base64encode(jsonencode(local.runtime_configuration))
  }
}
resource "oci_identity_dynamic_group" "app" {
  compartment_id = var.tenancy_ocid
  name           = "${var.name}-${random_id.suffix.hex}"
  description    = "Only this benchmark Container Instance"
  matching_rule  = "ALL {resource.type = 'computecontainerinstance', resource.id = '${oci_container_instances_container_instance.app.id}'}"
}
resource "oci_identity_policy" "app" {
  count          = var.runtime_config_delivery == "config_volume" ? 0 : 1
  compartment_id = var.compartment_ocid
  name           = "${var.name}-runtime-${random_id.suffix.hex}"
  description    = "Read only this deployment's runtime secret"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to read secret-bundles in compartment id ${var.compartment_ocid} where target.secret.id = '${oci_vault_secret.app[0].id}'"
  ]
}
resource "oci_identity_policy" "benchmark_workloads" {
  count          = length(local.benchmark_compartment_ocids) > 0 ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${var.name}-workloads-${random_id.suffix.hex}"
  description    = "Optional benchmark VM privileges in explicitly selected compartments"
  statements = concat(
    ["Allow dynamic-group ${oci_identity_dynamic_group.app.name} to inspect compartments in tenancy"],
    flatten([for c in local.benchmark_compartment_ocids : [
      "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to manage instance-family in compartment id ${c}",
      "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to manage volume-family in compartment id ${c}"
    ]]),
    [for c in local.benchmark_network_compartment_ocids : "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to use virtual-network-family in compartment id ${c}"]
  )
  lifecycle {
    precondition {
      condition     = length(local.benchmark_network_compartment_ocids) > 0
      error_message = "Select the network compartments when enabling benchmark VM provisioning."
    }
  }
}

locals {
  runtime_configuration = {
    app_secret         = random_password.app.result
    oidc_client_secret = oci_identity_domains_app.benchmark.client_secret
    oidc_client_id     = oci_identity_domains_app.benchmark.name
    public_url         = local.public_url
    oidc_domain_url    = trimsuffix(var.identity_domain_url, "/")
    oidc_issuer        = var.oidc_issuer
    allowed_subjects   = var.allowed_subjects
    authorization_mode = var.oidc_authorization_mode
    tls_key            = tls_private_key.app.private_key_pem
    tls_cert           = tls_self_signed_cert.app.cert_pem
    report_archive     = local.report_archive_config
  }
}
