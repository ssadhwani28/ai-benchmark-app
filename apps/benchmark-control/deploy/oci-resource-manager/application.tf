locals {
  runtime_secret_name = "${var.name}-runtime-${random_id.suffix.hex}"
}
resource "oci_container_instances_container_instance" "app" {
  compartment_id                       = var.compartment_ocid
  availability_domain                  = var.availability_domain
  display_name                         = "${var.name}-${random_id.suffix.hex}"
  shape                                = var.shape
  container_restart_policy             = "ALWAYS"
  graceful_shutdown_timeout_in_seconds = 30
  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }
  vnics {
    subnet_id = data.oci_core_subnet.existing.id
    # The supplied public subnet uses an Internet Gateway. Keep an address for
    # outbound registry/IAM access; the load balancer targets the private address.
    # Restrict shared security lists too: NSG grants are additive.
    is_public_ip_assigned = true
    nsg_ids               = [oci_core_network_security_group.app.id]
  }
  containers {
    display_name                   = "benchmark"
    image_url                      = var.app_image_url
    is_resource_principal_disabled = false
    command                        = ["python", "/bootstrap/runtime.py"]
    environment_variables = merge({
      OCI_REGION              = var.region
      PYTHONDONTWRITEBYTECODE = "1"
      PYTHONUNBUFFERED        = "1"
      BENCHMARK_CONFIG_SOURCE = var.runtime_config_delivery
      }, var.runtime_config_delivery == "config_volume" ? {
      BENCHMARK_CONFIG_FILE = "/run/benchmark-config/configuration.json"
      } : {
      BENCHMARK_VAULT_ID    = data.oci_kms_vault.existing[0].id
      BENCHMARK_SECRET_NAME = local.runtime_secret_name
      }, var.runtime_config_delivery == "kms_object_storage" ? {
      BENCHMARK_CONFIG_BUCKET       = local.archive_bucket_name
      BENCHMARK_CONFIG_NAMESPACE    = data.oci_objectstorage_namespace.archive[0].namespace
      BENCHMARK_CONFIG_REGION       = local.archive_region
      BENCHMARK_CONFIG_OBJECT       = local.runtime_config_object
      BENCHMARK_CONFIG_DEPLOYMENT   = local.runtime_config_deployment
      BENCHMARK_KMS_CRYPTO_ENDPOINT = data.oci_kms_vault.existing[0].crypto_endpoint
      BENCHMARK_KMS_KEY_ID          = data.oci_kms_key.existing[0].id
    } : {})
    volume_mounts {
      mount_path   = "/bootstrap"
      volume_name  = "bootstrap"
      is_read_only = true
    }
    dynamic "volume_mounts" {
      for_each = var.runtime_config_delivery == "config_volume" ? [1] : []
      content {
        mount_path   = "/run/benchmark-config"
        volume_name  = "private-configuration"
        is_read_only = true
      }
    }
    volume_mounts {
      mount_path  = "/data"
      volume_name = "data"
    }
  }
  volumes {
    name        = "bootstrap"
    volume_type = "CONFIGFILE"
    configs {
      file_name = "runtime.py"
      data      = filebase64("${path.module}/runtime.py")
    }
  }
  dynamic "volumes" {
    for_each = var.runtime_config_delivery == "config_volume" ? [1] : []
    content {
      name        = "private-configuration"
      volume_type = "CONFIGFILE"
      configs {
        file_name = "configuration.json"
        data      = sensitive(base64encode(jsonencode(local.runtime_configuration)))
      }
    }
  }
  volumes {
    name          = "data"
    volume_type   = "EMPTYDIR"
    backing_store = "EPHEMERAL_STORAGE"
  }
  dynamic "image_pull_secrets" {
    for_each = var.registry_username == "" ? [] : [1]
    content {
      secret_type       = "BASIC"
      registry_endpoint = split("/", var.app_image_url)[0]
      username          = base64encode(var.registry_username)
      password          = base64encode(var.registry_password)
    }
  }
  lifecycle {
    precondition {
      condition     = (var.registry_username == "") == (var.registry_password == "")
      error_message = "For a private image supply both registry username and token; otherwise leave both empty."
    }
  }
}
data "oci_core_vnic" "app" {
  vnic_id = oci_container_instances_container_instance.app.vnics[0].vnic_id
}
