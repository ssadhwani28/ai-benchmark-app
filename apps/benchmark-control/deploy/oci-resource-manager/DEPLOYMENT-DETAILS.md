# Deployment details and operations

[Back to the first-time deployment guide](README.md). For individual inputs, see
the [field reference](FIELD-REFERENCE.md).

## Network and IAM prerequisites

The Resource Manager form uses OCI's region, availability-domain, VCN and subnet
selectors. Before opening Create/Edit Stack, switch the OCI Console to the target
region and keep **Deployment region** aligned with it (it defaults to the current
Console region). The region variable configures the Terraform provider; it does
not move an existing Resource Manager stack between regions. OCI's documented
VCN/AD selector dependencies do not include an arbitrary region override, so a
provider region change alone must not be assumed to refresh those Console lists.
Choose the target region before selecting resources.

Select **VCN compartment** and then the VCN. Select **Subnet compartment** and then
a public subnet within that VCN. The compartment selectors default to the app/VCN
compartment respectively and can be changed for shared networks. They scope the
Console lists only; direct Terraform callers can leave them blank and provide
VCN/subnet OCIDs. An AD-specific subnet must match the selected AD; regional
subnets are accepted across ADs. The stack validates this before provisioning.
The selector types and dependencies follow the
[OCI Resource Manager schema reference](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/terraformconfigresourcemanager_topic-schema.htm).

**Allowed HTTPS client IPs / CIDRs** is a required text box. Enter your current
public source IP with `/32`, or approved corporate IPv4 CIDRs, one per line or
comma-separated. These create inbound TCP/443 rules on the load balancer NSG.
**Outbound SSH target networks** is optional: leave it blank unless connecting
to benchmark hosts over SSH. It creates outbound TCP/22 rules only. These fields
accept entered CIDRs rather than presenting a network-resource dropdown.

The old `allowed_client_cidrs` and `benchmark_target_cidrs` list inputs remain
supported for existing stacks/Terraform callers and are hidden in the form.
Their entries are combined with the new `*_text` fields and deduplicated; old
entries must be cleared explicitly if you intend to remove their access. A
missing/empty HTTPS allowlist, invalid IPv4 CIDR or unrestricted `/0` fails Plan.
Neither SSH targets nor HTTPS clients enable benchmark VM management permissions.

Read `https://<your-domain>/.well-known/openid-configuration` and copy `issuer`
exactly, including its trailing slash. It can differ from the domain URL. Verify
that the chosen MFA policy covers the operators and that their factors are
enrolled. `CustomWebAppTemplateId` is the default confidential application template;
override it if your domain uses another ID.

The existing subnet needs an internet gateway route, functional OCI DNS resolver,
and outbound access to the registry and Identity Domain (plus regional Secrets/KMS
APIs only for those optional delivery modes).
The app NSG permits DNS to the standard OCI resolver and HTTPS egress. Existing
security lists and NSGs are additive: **a broad shared subnet rule can still
permit other source IPs**. Use a suitably restricted existing subnet to enforce
the approved-source boundary; this stack deliberately does not edit shared rules.

Choose `CI.Standard.A1.Flex` for ARM64 or `CI.Standard.E4.Flex` for AMD64. Ensure
that the image architecture, available shape capacity and OCPU/memory limits match.
The image must include this repository's OCI IAM authentication implementation,
Python, OCI SDK and Uvicorn. An old passwordless image is not supported.

## Build and deploy independently

From the repository root:

```sh
python3 apps/benchmark-control/deploy/package_resource_manager.py
```

The output `apps/benchmark-control/dist/benchmark-resource-manager.zip` contains
Terraform, the Resource Manager form, runtime bootstrap, tests, this guide and
`application.zip` with buildable source. No state, local configuration, tokens,
private keys or developer-specific deployment scripts are included.

1. Build and push the image to your registry. From this repository, an ARM64 example is:

   ```sh
   docker buildx build --platform linux/arm64 \
     -t YOUR_REGISTRY/YOUR_NAMESPACE/benchmark:iam --push apps/benchmark-control
   ```

   Alternatively unzip `application.zip` from the stack ZIP and use that directory
   as the Docker build context. Record the pushed image's SHA256 digest. For E4,
   use `linux/amd64`. Image building/publishing is a prerequisite; Resource Manager
   does not build images or depend on access to the original private repository.
2. Create an OCI Resource Manager stack from the generated ZIP. Select Terraform
   1.5.x (local mocked tests require 1.7 or newer), fill the form and run Plan.
   Supply private registry tokens as sensitive variables, never in source control.
3. Review the plan, then Apply. Read `application_url`, `callback_url` and the public
   `tls_certificate_pem` output. Verify/trust the certificate before testing login.
4. Allow several minutes for IAM policy propagation and bootstrap. Test `/api/health`,
   then assign users/groups to the integrated application as described below.
   Sign in as an assigned user and complete MFA; an unassigned user must be denied.
   Anonymous protected `/api/` requests must return 401.

For local Terraform use, copy `terraform.tfvars.example` into a private
`terraform.tfvars`, fill it in, configure your own OCI provider authentication and
run `terraform init`, `terraform plan`, `terraform apply`. Resource Manager uses
its execution identity rather than your local OCI config files.

Resource Manager currently lists Terraform 1.5.x as supported; see the
[version reference](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Reference/terraformversions.htm).

The deployment identity must be able to manage Container Instances, their VNICs
and NSGs in the applicable compartments; manage network load balancers; read the
existing network; and manage tenancy dynamic groups and the relevant IAM policies.
Vault/key read access and secret creation are needed only for optional Vault modes.
It also needs application administration in the selected Identity Domain,
including permission to create/update/activate confidential apps and bind the
selected sign-on policy. In Resource Manager, grant these capabilities to the
stack execution principal; ordinary compartment compute access alone is insufficient.
Use a tenancy administrator to bootstrap those grants if needed. The stack cannot
grant its own deployment identity privileges it does not already possess.

## Manage access through the integrated IAM application

The default `oidc_authorization_mode="app_assignment"` makes IAM user/group
assignments the access authority. The stack sets `allow_access_control=true`
(**Enforce grants as authorization**) on its confidential application and retains
the selected sign-on/MFA policy. An authenticated but unassigned domain user is
not enough to access this app. See Oracle's
[confidential application authorization guidance](https://docs.oracle.com/en-us/iaas/Content/Identity/applications/add-confidential-application.htm).

After a successful Apply:

1. Read the `iam_application_id` output and find that exact application in your
   Identity Domain's **Integrated applications** list. Use the stack's generated
   application, not an older pilot/client or the template.
2. Under the application's **Users**, assign the user. Alternatively assign a
   group under **Groups**, then manage membership of that group in the domain.
3. Verify **Enforce grants as authorization** is enabled and the selected sign-on
   policy requires the expected MFA. The stack does not enroll authenticators.
4. Sign in with the assigned user through `application_url`. Test an unassigned
   domain user too: IAM should deny authorization. Their source CIDR must also
   be allowed if they connect from a different public network.

A new application starts with no user/group assignments. Assign at least one
operator after Apply. Assignments/group membership are administered in IAM and
are not Terraform-managed resources in this package, so adding a user/group does
not change the container volume or require a deployment. Each signed-in identity
still gets its own application account and owner-scoped profiles/jobs/reports.
All assigned users have the same available app capabilities, including any
optional VM provisioning privileges granted to the container principal.

Remove a user/group assignment to block new sign-ins. Existing app sessions are
not checked against the IAM directory on every request and can last until their
normal expiry (at most one hour and no longer than the ID token lifetime). There
is no immediate assignment-revocation/back-channel logout integration. Changing
network access, sign-on policy or subject restriction may be needed under your
normal incident response procedure; assignment removal alone is not instant
revocation of already-issued app sessions.

For an additional explicit subject restriction, select
`oidc_authorization_mode="subject_allowlist"` and supply `allowed_subjects`.
Access then requires **both** an IAM assignment and an exact subject match.
Only this mode displays/requires the subject list. Direct/manual application
config defaults to this legacy restrictive mode; enabling assignment mode uses
`APP_OIDC_AUTHORIZATION_MODE=app_assignment` and requires the corresponding IAM
client to enforce grants. The runtime volume/secret carries the selected mode.
Issuer, client audience, signature, expiry, PKCE, state, nonce, CSRF and cookie
checks remain enforced in both modes.

Upgrade using an image built from app **0.4.4 or later** that implements this mode;
the earlier 0.4.3 image still requires a subject allowlist. Update the stack ZIP
and image digest together, then review Plan. A container replacement can lose
ephemeral app data: preserve it or deploy a separate test stack as described below.
This upgrade intentionally replaces the IAM client registration once to enable
app-grant enforcement through creation, avoiding older provider full-PUT issues.
Assign users/groups to the new client shown by `iam_application_id`; old-client
assignments do not transfer automatically. Changing authorization mode forces a
fresh app sign-in. The stack enables grant
enforcement for legacy allowlist mode too, so existing operators must also be
assigned to the integrated application after this upgrade. Replacing the IAM
application changes its ID; assign operators to the replacement client.

## First boot and configuration updates

The network load balancer is created first, establishing the public origin before
Terraform registers the IAM client, generates the TLS certificate and creates the
container's configuration volume. The listener forwards encrypted TCP/443 to the
container’s private IP on port 443.
The container retains a public IP for outbound IAM/registry access through the
existing public subnet’s Internet Gateway; the stack grants backend ingress only
from the frontend NSG. The backend public address is not the application endpoint.
Existing broad subnet security-list grants can still expose it, so use restrictive
shared rules. The load balancer does not provide outbound NAT for private backends.
Source preservation is
disabled, so backend rules grant access from the frontend NSG. This ordering avoids
a dependency cycle between container creation and IAM/TLS configuration. The
endpoint stays stable across container replacements while the load balancer remains.

`runtime_config_delivery="config_volume"` is the default. The JSON configuration
is mounted read-only at `/run/benchmark-config/configuration.json`, separately from
writable `/data`. Bootstrap validates it before launching Uvicorn and creates
owner-only app/OAuth/TLS files in a private temporary directory. Secret values are
not put in environment variables or command arguments. Invalid configuration fails
closed. This mode makes no Vault/KMS calls; the app still uses its resource principal
for optional report archival and explicitly enabled OCI workflows.

**Private configuration is access-controlled, not encrypted by base64.** Anyone
with sufficient OCI container configuration or Terraform state access can retrieve
its values. Restrict these permissions. Updating a CONFIGFILE payload can replace
the Container Instance and lose ephemeral data; use a separate stack for testing
when preserving existing data is required. It has no in-place secret rotation API.

Optional Vault/KMS modes retain their 30-second configuration polling and retry
behavior; transient retrieval errors leave a running child alone. Auth mode is
always `oci_iam`. Browser traffic uses `https://PUBLIC_IP/` (default port 443).
Use HTTPS `/api/health` for readiness; ACTIVE alone does not prove app readiness.
No interactive container login is needed after a successful apply.

## Optional benchmark cloud access

The two optional VM compartment inputs are plain text, with blank meaning no
permissions. They accept comma/newline-separated compartment OCIDs or a JSON list
string, including `[]`. This avoids Resource Manager passing blank collection
expressions before Terraform can apply a default. For direct Terraform callers,
these two inputs are now strings: replace native lists with `jsonencode([...])`
or comma-separated text. Older Resource Manager values serialized as JSON lists
continue to work; blank saved strings also work with this package.

After a `Missing expression` failure for either field, upload this updated ZIP
through Edit Stack and save the configuration. Replacing only the container image
or rerunning the old job does not update the Terraform variable types. Run a new
Plan after updating the stack. No Apply is required to verify parsing.

These permissions are **not required to deploy the app container/load balancer,
sign in, or archive reports**. Leave both compartment lists empty unless you want
the running application to create/manage benchmark VMs. By default the principal
cannot provision VMs and needs no runtime-secret access.
To use the application's resource-principal VM workflow, explicitly supply
`benchmark_compartment_ocids` and `benchmark_network_compartment_ocids`. This adds
instance/volume management in only those workload compartments, network use in
only those network compartments, and compartment metadata inspection. Every
approved application operator can exercise these privileges: choose dedicated
benchmark compartments. SSH target access is separately controlled by
`benchmark_target_cidrs_text` (or the legacy list). Report archiving is configured through the archive inputs below; its bucket-scoped
permissions are generated automatically. Other service workflows need their own
service-specific policies or user-provided OCI profiles.
No existing tenancy-wide benchmark policy is assumed or reused. Other existing
policies matching the resource can still add privileges; IAM grants are additive.

## Report archive inputs and behavior

Archive settings appear in the Resource Manager form. `report_archive_enabled`
controls automatic upload of generated reports and defaults to false. Supply
`report_archive_bucket_name` for an existing bucket, or select
`report_archive_create_bucket=true` for a new private, versioned Standard-tier
bucket. A blank name generates a unique name for a new bucket. Namespace is
looked up automatically; users do not need to know it.

`report_archive_compartment_ocid` and `report_archive_region` default to the app's
compartment/region when blank, including support for an archive bucket in a
different OCI region. Existing buckets must be private, Standard-tier and in the
selected compartment; the stack checks those properties before use and never
changes the existing bucket's access level, versioning or ownership.
`report_archive_link_hours` controls read-only ZIP link expiry (1–8760 whole
hours; default 168). These links are bearer credentials; share them accordingly.

The stack configures the API and embedded report worker through the selected runtime
configuration delivery and grants the Container Instance group bucket inspection, report-prefix
object create/overwrite/read and PAR management for only the chosen bucket.
It does not grant object deletion or bucket configuration updates. Existing
IAM policies can add permissions beyond these generated grants.

The Reports page shows whether archiving is configured, its destination and link
expiry. Per-report status indicates pending/uploading/ready/failed; configured
status alone does not prove cloud access. The worker verifies the local bundle,
uploads ZIP/CSV/JSON/manifest, then reads bytes back and checks SHA-256 before
marking ready. Failed uploads retain the local report and can be retried. Existing
completed local reports are backfilled when archiving is enabled. Download links
are generated only after a verified archive is ready.

To stop uploads while retaining a managed archive bucket, change only
`report_archive_enabled=false`; keep `report_archive_create_bucket=true`.
Changing bucket ownership/name/region or destroying a stack with its managed
bucket is blocked by `prevent_destroy`. Deliberately hand off that bucket's
Terraform state ownership before retiring the stack; never remove this safeguard
as a routine upgrade step. An existing bucket is always outside stack ownership.
Reports persist in Object Storage, but this is not a database/profile backup.
A fresh SQLite database cannot automatically reconstruct its report catalogue;
preserve the database or saved archive links/object paths when migrating.

## Encrypted runtime delivery during a Secrets API outage

`runtime_config_delivery` defaults to `config_volume`, which needs no Vault. If you
prefer encrypted remote configuration and the Secrets retrieval service is
unavailable while the restored Vault's KMS crypto API is healthy, select
`kms_object_storage` and provide/create a private report bucket.

Terraform compresses and encrypts the runtime configuration through the same
existing AES-256 key, with application-bound authenticated context. Only KMS
ciphertext is stored under `runtime/<deployment>.json.enc` in the private bucket.
The container receives only object/key identifiers and uses its resource principal
to read exactly that object and decrypt using exactly that existing key. It gets
no key-encrypt or runtime-object write permission. Report permissions remain
restricted to `reports/*`; normal report links never point to runtime objects.
The managed Vault secret is retained, but this mode does not depend on its
retrieval service. IAM login, HTTPS, assignment/optional subject checks and private local secret files
remain enabled. No new Vault or KMS key is created.

Plaintext credentials remain in restricted Terraform state, just as with Vault
delivery; Object Storage never contains their plaintext. Valid new ciphertext
restarts Uvicorn, while temporary retrieval/decryption failures leave a healthy
running child alone. Changing the bootstrap/delivery mode can replace the
Container Instance; preserve data or deploy separately when it contains user data.

## Upgrading older stacks that created a Vault

Only optional Vault modes require an existing Vault/key. Old managed Vault/key resource
addresses are retained only as zero-count migration guards with `prevent_destroy`;
new deployments create neither. Do not apply this package directly over a legacy
stack without a deliberate Terraform state hand-off for those two resources.
The guards block their destruction rather than silently deleting a Vault used by
other apps. Reuse their actual OCIDs as inputs after ownership hand-off. A new,
separate stack can safely reference those existing Vault/key OCIDs immediately,
provided their original owner keeps them active. Runtime/bootstrap changes can
replace the Container Instance and lose ephemeral app data; review the plan.

## Lifecycle and limits

This is the temporary HTTPS public-IP test deployment. Its self-signed certificate
requires explicit browser trust. A network load balancer is provisioned; DNS,
trusted-certificate automation, API gateway, backups and high availability are not.

SQLite and artifacts live on ephemeral storage. A process restart preserves the
volume while the Container Instance exists, but **instance replacement/deletion
loses it**. Image, bootstrap, resource sizing or network changes may replace the
instance. Its private IP can change; Terraform updates the backend while the
frontend endpoint stays stable. Replacing the load balancer changes its public IP
and replaces the IAM client/certificate/configuration as required. Back up data and preserve the app encryption key before such
changes. Do not put SQLite WAL on a shared NFS volume or scale this as shared replicas.
Changing the app encryption key makes previously saved credentials unreadable.

Terraform state contains OAuth/registry credentials, the app key and TLS private
key even though Terraform marks them sensitive. In volume mode the OCI container
configuration also contains these values. Restrict Resource Manager stack,
state, job and sensitive-variable access. Never commit tfvars/state or publish
plan files. Runtime secret destruction follows OCI scheduled-deletion behavior and recovery
windows. Referenced Vault/key resources remain outside stack ownership. Managed
archive buckets use `prevent_destroy` to protect saved reports. Review a Destroy plan; existing network/domain/policy
objects referenced as inputs remain outside stack ownership.

This stack creates a fresh authenticated app. It does not adopt an existing
application or import its database, saved profiles or identity mappings.

## Validation

```sh
terraform init -backend=false
terraform validate
terraform test
python -m unittest discover -s tests -p 'test_*.py'
```

Terraform tests use mocked providers and no cloud mutations. Runtime tests cover
bootstrap waiting, secret rotation, transient failures, child exits and shutdown.
Changing an existing direct-public-IP deployment to this topology changes the
endpoint and can replace its container. Use a separate stack to preserve its data;
review any migration plan before applying. Existing Vault secrets may be scheduled
for deletion when switching delivery modes; shared Vaults/keys remain referenced.

A fresh-tenancy Apply and browser/MFA acceptance test remain necessary before
calling the package live validated.
