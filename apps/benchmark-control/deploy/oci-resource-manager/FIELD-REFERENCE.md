# Stack input reference

[Back to the first-time deployment guide](README.md).

For a first deployment, select the location and existing public network, provide
an image and private-registry credentials if needed, configure IAM and assign users/groups to the integrated app after Apply, and enter your allowed HTTPS client CIDRs. Keep
`runtime_config_delivery = "config_volume"` for no Vault dependency. Leave VM
permissions and SSH targets blank unless needed. Report archiving is optional.

**Required** means a value must be supplied or selected; review prefilled values.
**Optional** means the documented default is sufficient. **Conditional** means
another selection makes the value necessary. Examples below are illustrative:
replace `YOUR_*`, `<...>`, example OCIDs, login names and documentation IP ranges
with values from your own tenancy. Do not paste a placeholder into the stack.
Console selectors store the resource OCID/full AD name, not its display label.

### Deployment location and existing network

| Field / Terraform variable | Required? / default | How to choose it and example |
| --- | --- | --- |
| Tenancy OCID — `tenancy_ocid` | Required; usually prefilled by Resource Manager | Your tenancy's OCID, available in tenancy details; format `ocid1.tenancy.oc1..<unique_id>`. This is not the application compartment OCID. |
| Deployment region — `region` | Required; form defaults to the current Console region | First switch the OCI Console to your target region, then keep this selection aligned, e.g. `us-ashburn-1`. Existing network, AD and available container capacity must match this region. |
| Application compartment — `compartment_ocid` | Required; usually prefilled | Select the compartment that will own the app, load balancer and NSGs, e.g. a dedicated `benchmark-apps` compartment. The stored value is `ocid1.compartment.oc1..<unique_id>`. |
| Availability domain — `availability_domain` | Required | Select from the dropdown; use the full tenancy-specific name, e.g. `YOUR_PREFIX:US-ASHBURN-AD-1`, not just `AD-1`. An AD-specific subnet must match; a regional subnet is accepted across ADs. |
| Deployment name — `name` | Optional; `benchmark` | Choose a distinct name per independent app, e.g. `benchmark-test-01`. Use 3–30 lowercase letters, digits or hyphens, starting with a letter. Resource names also receive a generated suffix. |
| VCN compartment — `vcn_compartment_ocid` | Required in the form; defaults to the application compartment | Select where the existing VCN lives, e.g. `shared-network`. This only scopes the VCN dropdown. Direct Terraform callers may leave it blank. |
| Existing VCN — `vcn_ocid` | Required | Select an existing VCN from that compartment, e.g. `benchmark-vcn`. Direct Terraform uses its `ocid1.vcn.oc1.<region>.<unique_id>`. The stack does not create a VCN. |
| Subnet compartment — `subnet_compartment_ocid` | Required in the form; defaults to the VCN compartment | Select where the subnet lives; it can differ from the VCN compartment. This only scopes the subnet dropdown. Direct Terraform callers may leave it blank. |
| Existing public subnet — `subnet_ocid` | Required | Select a public subnet within the selected VCN, e.g. `benchmark-public`. Direct Terraform uses `ocid1.subnet.oc1.<region>.<unique_id>`. It must allow public IPs and have working Internet Gateway routing; selecting a VCN alone does not create these prerequisites. |

### Image, registry and container capacity

| Field / Terraform variable | Required? / default | How to choose it and example |
| --- | --- | --- |
| Container image URL pinned by digest — `app_image_url` | Required | Use a full image reference: `us-ashburn-1.ocir.io/YOUR_NAMESPACE/benchmark@sha256:<64_hex_characters>`. Copy the digest from your successful push/registry manifest. A tag such as `:latest` or `:v1` alone is rejected. The registry hostname can differ from the deployment region if reachable. |
| Private registry username — `registry_username` | Conditional; blank | Required with a token when the image repository is private. An OCI Identity Domain example is `YOUR_NAMESPACE/Default/operator@example.com`; use the namespace/domain/login belonging to the registry credential. Leave both registry fields blank for a public image. |
| Private registry token — `registry_password` | Conditional; blank; sensitive | Use an OCIR-compatible auth token belonging to the registry user with permission to pull the image, not the Console password, OCI API private key or IAM app client secret. Enter it in the sensitive Resource Manager field. Never put a real token in this README or commit it in tfvars. |
| Container Instance shape — `shape` | Optional; `CI.Standard.A1.Flex` | A1 requires a `linux/arm64` image; `CI.Standard.E4.Flex` requires `linux/amd64`. An ARM64-only image will not run on E4. Choose capacity available in your selected AD. |
| OCPUs — `ocpus` | Optional; `1` | Example `1` for the initial test container. Must be a positive whole number and supported by the selected shape/service limits. |
| Memory (GiB) — `memory_in_gbs` | Optional; `4` | Example `4`. Must be at least 1 GiB and satisfy the shape's OCPU/memory limits. This sizes the control app; benchmark VMs are configured separately in the app. |

The stack does not build/push images or create registry users/auth tokens. Publish
an image first and supply credentials from the repository owner for a private image.

### IAM authentication

| Field / Terraform variable | Required? / default | How to choose it and example |
| --- | --- | --- |
| Existing Identity Domain HTTPS URL — `identity_domain_url` | Required | Copy the existing domain's HTTPS URL from its details, e.g. `https://idcs-<domain_id>.identity.oraclecloud.com`. Use your domain's actual hostname; regional hostnames are also supported. Supply the origin only, without `/ui`, `/admin`, `/oauth2/...` or the application callback path. `:443` is accepted. |
| Exact issuer from domain discovery — `oidc_issuer` | Required | Open `<identity_domain_url>/.well-known/openid-configuration` and copy the JSON `issuer` exactly. Example: `https://identity.oraclecloud.com/`. Preserve the trailing slash when present; do not assume the issuer equals the domain URL. |
| Confidential Application template ID — `iam_template_id` | Optional; `CustomWebAppTemplateId` | Keep this default unless your Identity Domain requires a different supported template ID. This is a template identifier, not an existing application's client ID. |
| Existing MFA sign-on policy ID — `iam_mfa_signon_policy_id` | Required | Supply the ID/value of an existing application sign-on policy in this domain whose effective rules require MFA for your operators. `OciConsolePolicy` was used in the original test domain; use it only if that identifier exists and its rules apply in your domain. Do not substitute an arbitrary display name. The stack binds the policy but does not configure its rules or enroll authenticators. |
| Application access control — `oidc_authorization_mode` | Optional; `app_assignment` | Keep the default to authorize users/groups assigned to the integrated IAM application. IAM app-grant enforcement is always enabled by this stack. `subject_allowlist` adds a separate subject restriction on top of assignment. |
| Approved OIDC subject values — `allowed_subjects` | Conditional; default `[]`, hidden in assignment mode | Required only for `subject_allowlist`. Enter exact approved `sub` claim values, e.g. `operator@example.com`. For raw Terraform/JSON collection entry: `["operator@example.com"]`. In a form control that adds individual entries, add the login value itself. Do not add JSON brackets to an individual entry. Verify actual `sub` values; an email address, user OCID or SCIM GUID is not universally the correct subject. Matching is exact. |

The stack creates the confidential IAM application, client ID/secret, callback
and landing-page configuration. You do not need to register an IAM client manually
or supply its secret. All approved operators receive the app's available capabilities;
IAM assignments/subject allowlists do not define separate viewer/admin roles.

### HTTPS client access and optional SSH targets

| Field / Terraform variable | Required? / default | How to choose it and example |
| --- | --- | --- |
| Allowed HTTPS client IPs / CIDRs — `allowed_client_cidrs_text` | Required in the form | Enter the public egress IP your browser uses, with `/32`, e.g. `198.51.100.24/32` (example only), or an approved corporate CIDR. Separate multiple entries with commas/newlines: `198.51.100.24/32,203.0.113.0/24`. Use your public source IP, not your laptop's private `192.168.x.x` address, the LB's IP or the VCN CIDR. Rules allow inbound HTTPS on 443. `/0` is rejected. Update this value if your public source IP changes. |
| Outbound SSH target networks — `benchmark_target_cidrs_text` | Optional; blank | Leave blank unless the app will SSH to benchmark hosts. Example `10.0.1.0/24,10.0.2.10/32`. This permits outbound TCP/22; it does not create hosts, grant VM management, or configure inbound SSH on target hosts. Routing and target-side SSH rules must also allow the connection. |
| Legacy HTTPS source list — `allowed_client_cidrs` | Optional, hidden; `[]` | Existing Terraform callers may use `["198.51.100.24/32"]`. Combined with the text field; clear old entries explicitly to remove old access. At least one effective HTTPS source is required across both inputs. New form users should use the text field. |
| Legacy SSH target list — `benchmark_target_cidrs` | Optional, hidden; `[]` | Existing Terraform callers may use `["10.0.1.0/24"]`. Combined with the SSH text field. New form users should use the text field. |

### Runtime configuration and optional existing Vault

| Field / Terraform variable | Required? / default | How to choose it and example |
| --- | --- | --- |
| Runtime configuration delivery — `runtime_config_delivery` | Optional; `config_volume` | Keep `config_volume` to mount private read-only configuration without Vault. `vault` reads a secret from an existing Vault. `kms_object_storage` reads a KMS-encrypted private object and needs an existing Vault/key plus a private bucket, even when report archiving is disabled. |
| Existing Vault OCID — `existing_vault_ocid` | Conditional; blank | Required only for `vault` or `kms_object_storage`, hidden for `config_volume`. Example format `ocid1.vault.oc1.<region>.<unique_id>`. Use an existing ACTIVE Vault in the deployment region; the stack never creates/restores a Vault. |
| Existing enabled AES-256 key OCID — `existing_vault_key_ocid` | Conditional; blank | Required only for `vault` or `kms_object_storage`. Example format `ocid1.key.oc1.<region>.<unique_id>`. Select an ENABLED AES-256 key from that Vault. This is a key OCID, not key material or a key-version OCID. |

### Optional benchmark VM permissions

These fields control what the **running application** can do through its resource
principal. They are not needed to deploy the application/LB, sign in or archive
reports, and setting them does not immediately launch a benchmark VM.

| Field / Terraform variable | Required? / default | How to choose it and example |
| --- | --- | --- |
| Optional benchmark VM compartments — `benchmark_compartment_ocids` | Optional; blank | Compartments in which the app may manage benchmark instances and boot/block volumes. Enter actual compartment OCIDs, e.g. `ocid1.compartment.oc1..<workload_id>`, with commas/newlines for more than one. Leave blank for no generated VM provisioning permissions. |
| Optional benchmark network compartments — `benchmark_network_compartment_ocids` | Conditional; blank | Required when VM compartments above are supplied. Enter compartments containing networks used by those benchmark VMs, e.g. `ocid1.compartment.oc1..<network_id>`. Grants network use; it is not the application's network selector and is not a list of VCN/subnet OCIDs. Otherwise leave blank. |

Both are **text inputs**, not native Terraform list variables. A blank field or
literal `[]` means no compartments. For a direct Terraform JSON-list alternative,
use `benchmark_compartment_ocids = jsonencode(["YOUR_COMPARTMENT_OCID"])`.
Do not use `benchmark_compartment_ocids = ["..."]` in current tfvars: the variable
is a string. All approved operators can exercise these permissions; use dedicated
benchmark compartments. Existing OCI policies can add privileges independently.

### Optional report archive

| Field / Terraform variable | Required? / default | How to choose it and example |
| --- | --- | --- |
| Enable automatic report archiving — `report_archive_enabled` | Optional; `false` | Set `true` to archive completed generated reports and backfill completed local reports. A bucket and scoped principal permissions are then configured. Report generation itself does not require archiving. |
| Create a new private versioned report bucket — `report_archive_create_bucket` | Optional; `false` | Select `true` for the stack to create a private, versioned Standard-tier bucket. Select `false` to use an existing bucket when archiving is enabled. This flag creates/retains a bucket even if archiving is disabled; keep it `true` later when disabling uploads so the managed bucket stays in the stack. |
| Report bucket name — `report_archive_bucket_name` | Conditional; blank | Existing bucket: exact bucket name such as `team-benchmark-reports`, not its OCID, namespace, URL or a folder prefix. New bucket: optional name; blank generates `<deployment-name>-reports-<suffix>`. A private bucket is also needed for `kms_object_storage` delivery regardless of the archive toggle. |
| Report bucket compartment OCID — `report_archive_compartment_ocid` | Optional; blank uses application compartment | Supply a different bucket compartment's `ocid1.compartment.oc1..<unique_id>` only when necessary. For an existing bucket it must match that bucket's actual compartment. |
| Report bucket region — `report_archive_region` | Optional; blank uses deployment region | Example `eu-frankfurt-1` for a bucket located there. Supply the actual region identifier, not a display name such as `Germany Central`. Cross-region bucket access must be permitted/reachable. |
| Report download-link lifetime (hours) — `report_archive_link_hours` | Optional; `168` | Whole hours from `1` through `8760`; e.g. `24` for one day. Controls expiry of read-only report ZIP links, which are bearer credentials. It is not an object retention/deletion period. |

Existing archive buckets must be private, use Standard storage, and belong to the
selected bucket compartment/region. The stack does not change an existing bucket's
ownership/access settings. Bucket namespace is discovered automatically.

### Values generated by the stack

Do not enter an application public IP, port, IAM callback/client ID/client secret,
app encryption key, TLS private key/certificate, archive namespace, dynamic-group
ID or NSG ID as additional inputs. The stack generates or discovers them. HTTPS
uses port **443**. After Apply, use `application_url` and `callback_url` outputs;
verify/trust the `tls_certificate_pem` output before testing the self-signed endpoint.

### Example: first deployment without Vault or benchmark VM permissions

This is Terraform syntax. In Resource Manager, select equivalent values in the
form; do not paste the whole block into a single field. Replace all placeholders,
the illustrative subject and the documentation-only client IP before Plan.

```hcl
tenancy_ocid        = "YOUR_TENANCY_OCID"
compartment_ocid    = "YOUR_APPLICATION_COMPARTMENT_OCID"
region              = "us-ashburn-1"
availability_domain = "YOUR_PREFIX:US-ASHBURN-AD-1"
name                = "benchmark-test-01"
vcn_ocid            = "YOUR_EXISTING_VCN_OCID"
subnet_ocid         = "YOUR_EXISTING_PUBLIC_SUBNET_OCID"
app_image_url       = "us-ashburn-1.ocir.io/YOUR_NAMESPACE/benchmark@sha256:REPLACE_WITH_64_HEX_DIGITS"
shape               = "CI.Standard.A1.Flex" # requires an ARM64 image

identity_domain_url      = "https://YOUR_IDENTITY_DOMAIN_HOST"
oidc_issuer              = "https://identity.oraclecloud.com/" # verify discovery
iam_mfa_signon_policy_id = "YOUR_EXISTING_MFA_POLICY_ID"
oidc_authorization_mode  = "app_assignment" # assign users/groups in IAM after Apply
# allowed_subjects = ["operator@example.com"] # only with subject_allowlist
allowed_client_cidrs_text = "198.51.100.24/32" # replace with your public IP

runtime_config_delivery             = "config_volume"
benchmark_compartment_ocids         = "" # no generated benchmark VM permissions
benchmark_network_compartment_ocids = ""
report_archive_enabled              = false

# If the image repository is private, BOTH fields are required:
# registry_username = "YOUR_NAMESPACE/Default/YOUR_USERNAME"
# Supply registry_password separately in Resource Manager's sensitive field.
```

For a private image, the example is incomplete until both registry credentials
are supplied. Keep `ocpus=1`, `memory_in_gbs=4` and the app template default unless
your capacity/domain requirements differ. Start with a new stack for a separate
test application to preserve any existing app's ephemeral database.

### Example: archive to an existing bucket

Add to the first-deployment values (using your bucket's actual name/location):

```hcl
report_archive_enabled          = true
report_archive_create_bucket    = false
report_archive_bucket_name      = "team-benchmark-reports"
report_archive_compartment_ocid = "YOUR_BUCKET_COMPARTMENT_OCID" # omit if same as app
report_archive_region           = "us-ashburn-1"                 # omit if same as app
report_archive_link_hours       = 24
```

For a new stack-managed bucket, instead set `report_archive_create_bucket=true`;
leave the bucket name blank to generate one, or provide an available name. No Vault
inputs are needed with `config_volume`, whether archiving is enabled or disabled.

### Example: allow benchmark VM provisioning

Only add this when operators need the app's resource-principal VM workflow:

```hcl
benchmark_compartment_ocids         = "YOUR_WORKLOAD_COMPARTMENT_OCID"
benchmark_network_compartment_ocids = "YOUR_BENCHMARK_NETWORK_COMPARTMENT_OCID"
benchmark_target_cidrs_text         = "10.0.1.0/24" # if SSHing to hosts in this network
```

The two compartment values can be the same compartment if it owns both workloads
and their networks. Supply actual OCIDs, not the placeholder strings above.

