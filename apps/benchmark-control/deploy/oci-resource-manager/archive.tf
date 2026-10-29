locals {
  archive_region         = var.report_archive_region == "" ? var.region : var.report_archive_region
  archive_compartment    = var.report_archive_compartment_ocid == "" ? var.compartment_ocid : var.report_archive_compartment_ocid
  archive_storage_needed = var.report_archive_enabled || var.report_archive_create_bucket || var.runtime_config_delivery == "kms_object_storage"
  archive_bucket_name    = var.report_archive_create_bucket ? oci_objectstorage_bucket.reports[0].name : var.report_archive_bucket_name
  report_archive_config = {
    enabled    = var.report_archive_enabled
    bucket     = var.report_archive_enabled ? local.archive_bucket_name : ""
    namespace  = var.report_archive_enabled ? data.oci_objectstorage_namespace.archive[0].namespace : ""
    region     = local.archive_region
    link_hours = var.report_archive_link_hours
  }
}
provider "oci" {
  alias  = "archive"
  region = local.archive_region
}
data "oci_objectstorage_namespace" "archive" {
  provider       = oci.archive
  count          = local.archive_storage_needed ? 1 : 0
  compartment_id = var.tenancy_ocid
}
resource "oci_objectstorage_bucket" "reports" {
  provider       = oci.archive
  count          = var.report_archive_create_bucket ? 1 : 0
  compartment_id = local.archive_compartment
  namespace      = data.oci_objectstorage_namespace.archive[0].namespace
  name           = var.report_archive_bucket_name == "" ? "${var.name}-reports-${random_id.suffix.hex}" : var.report_archive_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"
  # Turning uploads off leaves this resource intact. Explicit ownership changes
  # or stack destruction must not silently delete an archive bucket.
  lifecycle { prevent_destroy = true }
}
data "oci_objectstorage_bucket" "reports" {
  provider  = oci.archive
  count     = (var.report_archive_enabled || var.runtime_config_delivery == "kms_object_storage") && !var.report_archive_create_bucket ? 1 : 0
  namespace = data.oci_objectstorage_namespace.archive[0].namespace
  name      = var.report_archive_bucket_name
  lifecycle {
    precondition {
      condition     = var.report_archive_bucket_name != ""
      error_message = "Supply an existing archive bucket name or select Create a new report bucket."
    }
    postcondition {
      condition     = self.access_type == "NoPublicAccess" && self.storage_tier == "Standard" && self.compartment_id == local.archive_compartment
      error_message = "The existing archive bucket must be private, use Standard storage and belong to the selected bucket compartment."
    }
  }
}
resource "oci_identity_policy" "report_archive" {
  count          = var.report_archive_enabled ? 1 : 0
  compartment_id = local.archive_compartment
  name           = "${var.name}-reports-${random_id.suffix.hex}"
  description    = "Read/write verified reports and manage download links in the selected bucket only"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to read buckets in compartment id ${local.archive_compartment} where target.bucket.name = '${local.archive_bucket_name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to manage objects in compartment id ${local.archive_compartment} where all {target.bucket.name = '${local.archive_bucket_name}', target.object.name = 'reports/*', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_OVERWRITE', request.permission = 'OBJECT_READ'}}",
    "Allow dynamic-group ${oci_identity_dynamic_group.app.name} to manage buckets in compartment id ${local.archive_compartment} where all {target.bucket.name = '${local.archive_bucket_name}', request.permission = 'PAR_MANAGE'}"
  ]
  depends_on = [data.oci_objectstorage_bucket.reports]
}
