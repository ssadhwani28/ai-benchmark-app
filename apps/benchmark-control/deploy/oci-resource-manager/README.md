# Deploy AI Benchmark Control on OCI

This guide provisions **one independent app** using OCI Resource Manager (RMS).
The stack creates a Container Instance, Network Load Balancer, IAM integrated app
and HTTPS endpoint on **443**. It uses your existing VCN and public subnet.
TLS terminates in the container; the NLB forwards encrypted traffic.
**No Vault is required with the defaults.**

## 1. Have these ready

- OCI permissions to create Container Instances, network load balancers, NSGs,
  dynamic groups, policies and an application in your Identity Domain. See
  [deployment permissions](DEPLOYMENT-DETAILS.md#build-and-deploy-independently).
- An existing public subnet with Internet Gateway routing and OCI DNS access.
  The stack does not create or change shared routes, gateways or security lists.
- An accessible app image built from **version 0.4.4 or later**, pinned by digest.
  For a private OCIR image, you also need a registry username and auth token
  with pull access. A GitHub checkout does not publish an image automatically.
- Your Identity Domain URL, its discovery issuer and an existing sign-on policy
  that requires MFA for your operators. Their authenticator enrollment must
  already be complete.
- Your browser's public source IP/CIDR, such as `YOUR_PUBLIC_IP/32`.

For a different tenancy, use that tenancy's network, IAM values and accessible
registry image. Do not copy another deployment's OCIDs or credentials.

## 2. Get the stack ZIP

Use `benchmark-resource-manager.zip` from a project GitHub Release **if one has
been published**. Otherwise, clone the repository and run this from its root:

```sh
python3 apps/benchmark-control/deploy/package_resource_manager.py
```

The generated file is:

```text
apps/benchmark-control/dist/benchmark-resource-manager.zip
```

The ZIP is generated locally and excluded from Git. It includes the Terraform
stack and `application.zip` with buildable app source. If you need to build/push
your own image, follow the [image build instructions](DEPLOYMENT-DETAILS.md#build-and-deploy-independently).

## 3. Create the Resource Manager stack

Select your target region in the OCI Console, then open **Developer Services →
Resource Manager → Stacks → Create stack** and upload the ZIP. Choose a Terraform
version compatible with `versions.tf` (the stack supports 1.5.x).

Review prefilled tenancy/compartment values. Complete these fields:

| Fields | What to choose |
| --- | --- |
| Deployment region and availability domain | Keep the region aligned with the Console; select a full AD name from the dropdown. |
| VCN compartment, VCN, subnet compartment and public subnet | Select your existing network. A regional subnet works across ADs; an AD-specific subnet must match the selected AD. |
| Container image URL | Full digest reference: `REGISTRY/NAMESPACE/REPOSITORY@sha256:<64_hex_characters>`. A tag alone is rejected. |
| Private registry username and token | Supply both for a private image. Use an auth token, not your OCI Console password. |
| Identity Domain HTTPS URL | Copy the domain's HTTPS origin from its details; do not include an OAuth or Console path. |
| Exact issuer | Open `<domain-url>/.well-known/openid-configuration` and copy `issuer` exactly, including its trailing slash. |
| Existing MFA sign-on policy ID | Use a policy ID from that domain whose rules require MFA. The stack binds the policy; it does not configure its rules. |
| Allowed HTTPS client IPs / CIDRs | Enter your browser's public source IP with `/32`, or approved corporate CIDRs. Multiple entries can be comma/newline separated. Do not enter the app/LB IP or your laptop's private LAN IP. |

Examples and descriptions for **every field** are in the
[field reference](FIELD-REFERENCE.md).

Keep these defaults for a first test:

| Field | Value |
| --- | --- |
| Application access control | `app_assignment` — manage users/groups in IAM after Apply. |
| Runtime configuration delivery | `config_volume` — leave Vault/key inputs blank. |
| Shape / OCPUs / memory | `CI.Standard.A1.Flex` / `1` / `4` GiB, with an ARM64 image. Select E4 only with an AMD64 image. |
| Benchmark VM/network permissions | Leave both text fields blank. These are needed only if the running app will provision benchmark VMs. |
| Outbound SSH targets | Leave blank unless the app will SSH to benchmark hosts. |
| Report archive | Disabled. To enable it, choose an existing private Standard bucket or let the stack create one; see the [archive example](FIELD-REFERENCE.md#example-archive-to-an-existing-bucket). |

An approved OIDC subject list is **not required** in `app_assignment` mode.
Check shared subnet security rules: OCI rules are additive, so broad existing
rules can permit access beyond the source CIDRs configured here.

## 4. Plan and apply

Create the stack and run **Plan**. Review the resources, then run **Apply**.
After it succeeds, read these outputs:

- `application_url` — the HTTPS endpoint to open.
- `iam_application_id` — the IAM app to assign users/groups to.
- `tls_certificate_pem` — the public self-signed certificate to verify/trust.

This deploys a fresh app. Container replacement/deletion loses its ephemeral
SQLite database and local artifacts. Preserve your data before replacing a
container. Report archiving does not back up the database or saved profiles.

## 5. Assign users and sign in

In your Identity Domain, find the generated app under **Integrated applications**
using `iam_application_id`. Assign your user under **Users**, or assign a group
under **Groups**. Verify **Enforce grants as authorization** remains enabled.
A new app has no user/group assignments until you add them.

Verify/trust the certificate, open `application_url`, click **Sign in with OCI
IAM**, and complete MFA. Test an unassigned user too: IAM should deny access.
You can add users/groups later without updating the stack or redeploying the app.
Removing an assignment blocks new sign-ins; existing app sessions can last up to
one hour. All assigned users have the same available app capabilities.

## If something goes wrong

| Symptom | Check |
| --- | --- |
| `Missing expression` for optional VM compartment fields | Upload the current ZIP through Edit Stack, save, then run a new Plan. These fields are now text: blank or `[]` means disabled. Rerunning an old job does not update its configuration. |
| Image pull fails | Check image digest, ARM64/AMD64 compatibility, registry username/token and pull permissions. |
| Browser cannot reach the app | Check `/api/health` at the HTTPS endpoint, your current public source CIDR, subnet routing and NSG/security-list rules. |
| IAM rejects sign-in | Check assignment to the exact generated IAM app, issuer, sign-on policy and MFA enrollment. |
| Reports stay local | Archiving defaults to disabled. If enabled, check the Reports page's destination/status and the private bucket's region/permissions. |

For bootstrap behavior, IAM/session details, archive permissions, upgrade limits
and developer validation, see [deployment details](DEPLOYMENT-DETAILS.md).
