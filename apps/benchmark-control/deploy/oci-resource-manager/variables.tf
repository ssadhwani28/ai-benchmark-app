variable "tenancy_ocid" { type = string }
variable "compartment_ocid" { type = string }
variable "region" { type = string }
variable "availability_domain" { type = string }
variable "vcn_ocid" { type = string }
variable "subnet_ocid" { type = string }
variable "name" {
  type    = string
  default = "benchmark"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,29}$", var.name))
    error_message = "Use 3–30 lowercase letters, digits or hyphens, starting with a letter."
  }
}
variable "app_image_url" {
  type        = string
  description = "Your own registry image, built from the included source, pinned by SHA256 digest."
  validation {
    condition     = can(regex("^[^ /]+/[^ ]+@sha256:[a-f0-9]{64}$", var.app_image_url))
    error_message = "Supply a fully qualified registry image pinned with @sha256:<64 hex digits>."
  }
}
variable "registry_username" {
  type        = string
  default     = ""
  description = "For a private registry, supply its username (OCIR: namespace/domain/username)."
}
variable "registry_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Private registry token. Empty username and token selects a public image."
}
variable "shape" {
  type    = string
  default = "CI.Standard.A1.Flex"
  validation {
    condition     = contains(["CI.Standard.A1.Flex", "CI.Standard.E4.Flex"], var.shape)
    error_message = "Choose A1 (ARM64) or E4 (AMD64); the image must support that architecture."
  }
}
variable "ocpus" {
  type    = number
  default = 1
  validation {
    condition     = var.ocpus >= 1 && floor(var.ocpus) == var.ocpus
    error_message = "OCPUs must be a positive integer."
  }
}
variable "memory_in_gbs" {
  type    = number
  default = 4
  validation {
    condition     = var.memory_in_gbs >= 1
    error_message = "Memory must be at least 1 GiB and within the chosen shape's limits."
  }
}
variable "identity_domain_url" {
  type = string
  validation {
    condition     = can(regex("^https://[a-zA-Z0-9.-]+(:443)?/?$", var.identity_domain_url))
    error_message = "Supply the existing Identity Domain's HTTPS origin."
  }
}
variable "oidc_issuer" {
  type        = string
  description = "Exact issuer, including trailing slash if present, from the domain /.well-known/openid-configuration."
  validation {
    condition     = can(regex("^https://[a-zA-Z0-9.-]+(:443)?/?$", var.oidc_issuer))
    error_message = "Issuer must be an HTTPS origin copied exactly from discovery."
  }
}
variable "iam_template_id" {
  type    = string
  default = "CustomWebAppTemplateId"
}
variable "iam_mfa_signon_policy_id" {
  type        = string
  description = "Existing application sign-on policy ID that requires MFA. The stack binds, but does not modify, this policy."
  validation {
    condition     = length(trimspace(var.iam_mfa_signon_policy_id)) > 0
    error_message = "Select an existing MFA sign-on policy; an empty binding is not supported."
  }
}
variable "allowed_subjects" {
  type        = list(string)
  default     = []
  description = "Optional additional restriction in subject_allowlist mode. Exact OIDC sub values, not assumed user OCIDs/SCIM GUIDs."
  validation {
    condition     = alltrue([for s in var.allowed_subjects : trimspace(s) == s && length(s) > 0 && !strcontains(s, ",")])
    error_message = "Subjects must be exact, nonempty strings without commas or surrounding spaces."
  }
}
variable "allowed_client_cidrs" {
  type        = list(string)
  default     = []
  description = "Legacy approved-source list; combined with allowed_client_cidrs_text."
  validation {
    condition     = alltrue([for c in var.allowed_client_cidrs : can(cidrnetmask(c)) && try(tonumber(split("/", c)[1]) > 0, false)])
    error_message = "Supply approved IPv4 source CIDRs; unrestricted /0 is not allowed."
  }
}
variable "benchmark_target_cidrs" {
  type        = list(string)
  default     = []
  description = "Optional IPv4 benchmark target networks for outbound SSH."
  validation {
    condition     = alltrue([for c in var.benchmark_target_cidrs : can(cidrnetmask(c)) && try(tonumber(split("/", c)[1]) > 0, false)])
    error_message = "SSH target CIDRs must be valid IPv4 networks, narrower than /0."
  }
}
variable "benchmark_compartment_ocids" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional benchmark VM compartment OCIDs; blank disables permissions. Accepts comma/newline-separated OCIDs or a JSON list string."
  validation {
    condition     = alltrue([for c in try(tolist(jsondecode(var.benchmark_compartment_ocids)), compact([for value in regexall("[^,\\r\\n]+", var.benchmark_compartment_ocids) : trimspace(value)])) : can(regex("^ocid1[.]compartment[.][^.]*[.][^.]*[.][a-zA-Z0-9]+$", c))])
    error_message = "Leave blank for no permissions, or enter compartment OCIDs separated by commas/newlines (a JSON list string is also accepted)."
  }
}
variable "benchmark_network_compartment_ocids" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional benchmark network compartment OCIDs; blank disables permissions. Accepts comma/newline-separated OCIDs or a JSON list string."
  validation {
    condition     = alltrue([for c in try(tolist(jsondecode(var.benchmark_network_compartment_ocids)), compact([for value in regexall("[^,\\r\\n]+", var.benchmark_network_compartment_ocids) : trimspace(value)])) : can(regex("^ocid1[.]compartment[.][^.]*[.][^.]*[.][a-zA-Z0-9]+$", c))])
    error_message = "Leave blank for no permissions, or enter compartment OCIDs separated by commas/newlines (a JSON list string is also accepted)."
  }
}

variable "existing_vault_ocid" {
  type        = string
  default     = ""
  description = "Existing OCI Vault OCID. This stack never creates a Vault."
  validation {
    condition     = var.existing_vault_ocid == "" || startswith(var.existing_vault_ocid, "ocid1.vault.")
    error_message = "An existing Vault OCID is required; no new Vault is provisioned."
  }
}
variable "existing_vault_key_ocid" {
  type        = string
  default     = ""
  description = "Existing enabled AES-256 key OCID in that Vault."
  validation {
    condition     = var.existing_vault_key_ocid == "" || startswith(var.existing_vault_key_ocid, "ocid1.key.")
    error_message = "An existing AES-256 key OCID in the selected Vault is required."
  }
}
variable "report_archive_enabled" {
  type        = bool
  default     = false
  description = "Automatically archive completed generated reports to private Object Storage."
}
variable "report_archive_create_bucket" {
  type        = bool
  default     = false
  description = "Create and retain a private versioned report bucket. Keep true when disabling uploads to retain its management."
}
variable "report_archive_bucket_name" {
  type        = string
  default     = ""
  description = "Existing bucket name, or optional name for a new bucket (blank generates one)."
  validation {
    condition     = var.report_archive_bucket_name == "" || can(regex("^[a-zA-Z0-9_.-]{1,256}$", var.report_archive_bucket_name))
    error_message = "Bucket names may contain 1–256 letters, numbers, periods, underscores and hyphens."
  }
}
variable "report_archive_compartment_ocid" {
  type        = string
  default     = ""
  description = "Bucket compartment OCID; blank uses the application compartment."
}
variable "report_archive_region" {
  type        = string
  default     = ""
  description = "Bucket region; blank uses the application region."
}
variable "report_archive_link_hours" {
  type    = number
  default = 168
  validation {
    condition     = var.report_archive_link_hours >= 1 && var.report_archive_link_hours <= 8760 && floor(var.report_archive_link_hours) == var.report_archive_link_hours
    error_message = "Download links must expire after 1–8760 whole hours."
  }
}
variable "runtime_config_delivery" {
  type        = string
  default     = "config_volume"
  description = "config_volume mounts private read-only configuration without Vault. Optional vault and kms_object_storage modes require an existing Vault/key."
  validation {
    condition     = contains(["config_volume", "vault", "kms_object_storage"], var.runtime_config_delivery)
    error_message = "Select config_volume, vault or kms_object_storage."
  }
}

# Resource Manager picker scopes; direct Terraform callers can keep these blank.
variable "vcn_compartment_ocid" {
  type        = string
  default     = ""
  description = "VCN compartment used to populate the Resource Manager VCN selector."
}
variable "subnet_compartment_ocid" {
  type        = string
  default     = ""
  description = "Subnet compartment used to populate the Resource Manager subnet selector."
}
variable "allowed_client_cidrs_text" {
  type        = string
  default     = ""
  description = "Approved IPv4 source CIDRs for HTTPS 443, separated by newlines or commas; combined with the legacy list."
  validation {
    condition     = alltrue([for value in regexall("[^,\\r\\n]+", var.allowed_client_cidrs_text) : can(cidrnetmask(trimspace(value))) && try(tonumber(split("/", trimspace(value))[1]) > 0, false) if trimspace(value) != ""])
    error_message = "Enter valid IPv4 CIDRs, one per line or comma-separated. Unrestricted /0 is not allowed."
  }
}
variable "benchmark_target_cidrs_text" {
  type        = string
  default     = ""
  description = "Optional outbound SSH target CIDRs, separated by newlines or commas; combined with the legacy list."
  validation {
    condition     = alltrue([for value in regexall("[^,\\r\\n]+", var.benchmark_target_cidrs_text) : can(cidrnetmask(trimspace(value))) && try(tonumber(split("/", trimspace(value))[1]) > 0, false) if trimspace(value) != ""])
    error_message = "Enter valid IPv4 SSH target CIDRs, one per line or comma-separated, narrower than /0."
  }
}

variable "oidc_authorization_mode" {
  type        = string
  default     = "app_assignment"
  description = "app_assignment admits users/groups assigned to the integrated IAM application. subject_allowlist additionally restricts access to allowed_subjects."
  validation {
    condition     = contains(["app_assignment", "subject_allowlist"], var.oidc_authorization_mode)
    error_message = "Choose app_assignment or subject_allowlist."
  }
}
