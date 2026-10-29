output "application_url" { value = local.public_url }
output "callback_url" { value = "${local.public_url}/auth/callback" }
output "container_instance_ocid" { value = oci_container_instances_container_instance.app.id }
output "iam_application_id" { value = oci_identity_domains_app.benchmark.id }
output "runtime_secret_ocid" { value = try(oci_vault_secret.app[0].id, null) }
output "network_security_group_ocid" { value = oci_core_network_security_group.app.id }
output "tls_certificate_pem" {
  value       = tls_self_signed_cert.app.cert_pem
  description = "Public self-signed certificate; verify/trust this before testing HTTPS. Contains no private key."
}

output "report_archive" {
  value       = local.report_archive_config
  description = "Effective archive settings delivered to the application."
}
output "managed_report_bucket_name" {
  value       = var.report_archive_create_bucket ? local.archive_bucket_name : null
  description = "Retained managed report bucket, including when automatic archiving is disabled."
}
