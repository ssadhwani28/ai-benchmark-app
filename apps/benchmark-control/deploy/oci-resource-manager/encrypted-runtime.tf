# Alternative delivery for deployments where the Secrets retrieval service is
# unavailable. Object Storage contains only authenticated KMS ciphertext.
locals {
  runtime_config_deployment = "${var.name}-${random_id.suffix.hex}"
  runtime_config_object     = "runtime/${local.runtime_config_deployment}.json.enc"
}
data "oci_kms_encrypted_data" "runtime" {
  count           = var.runtime_config_delivery == "kms_object_storage" ? 1 : 0
  key_id          = data.oci_kms_key.existing[0].id
  crypto_endpoint = data.oci_kms_vault.existing[0].crypto_endpoint
  plaintext       = base64gzip(jsonencode(local.runtime_configuration))
  associated_data = { purpose = "runtime-config", deployment = local.runtime_config_deployment }
}
# KMS encryption uses random nonces. Preserve the envelope until actual runtime
# settings change, rather than rewriting the object on every refresh/plan.
resource "terraform_data" "runtime_envelope" {
  count            = var.runtime_config_delivery == "kms_object_storage" ? 1 : 0
  input            = data.oci_kms_encrypted_data.runtime[0].ciphertext
  triggers_replace = sha256(jsonencode(local.runtime_configuration))
  lifecycle { ignore_changes = [input] }
}
resource "oci_objectstorage_object" "runtime" {
  provider     = oci.archive
  count        = var.runtime_config_delivery == "kms_object_storage" ? 1 : 0
  namespace    = data.oci_objectstorage_namespace.archive[0].namespace
  bucket       = local.archive_bucket_name
  object       = local.runtime_config_object
  content      = terraform_data.runtime_envelope[0].output
  content_type = "application/octet-stream"
  depends_on   = [oci_identity_policy.runtime_object, oci_identity_policy.runtime_decrypt, data.oci_objectstorage_bucket.reports]
}
resource "oci_identity_policy" "runtime_object" {
  count          = var.runtime_config_delivery == "kms_object_storage" ? 1 : 0
  compartment_id = local.archive_compartment
  name           = "${var.name}-config-read-${random_id.suffix.hex}"
  description    = "Read exactly this app's encrypted runtime object"
  statements     = ["Allow dynamic-group ${oci_identity_dynamic_group.app.name} to read objects in compartment id ${local.archive_compartment} where all {target.bucket.name = '${local.archive_bucket_name}', target.object.name = '${local.runtime_config_object}'}"]
}
resource "oci_identity_policy" "runtime_decrypt" {
  count          = var.runtime_config_delivery == "kms_object_storage" ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${var.name}-config-decrypt-${random_id.suffix.hex}"
  description    = "Decrypt runtime configuration using only the supplied existing key"
  statements     = ["Allow dynamic-group ${oci_identity_dynamic_group.app.name} to use keys in compartment id ${data.oci_kms_key.existing[0].compartment_id} where all {target.key.id = '${data.oci_kms_key.existing[0].id}', request.permission = 'KEY_DECRYPT'}"]
}
