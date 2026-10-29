# AI Inference Benchmark Control

Deploy an OCI app to manage benchmark VMs, run vLLM/GuideLLM workloads and generate
reports. Users sign in through OCI IAM.

## Provision your first app

Use the [step-by-step Resource Manager guide](apps/benchmark-control/deploy/oci-resource-manager/README.md).
It covers prerequisites, required inputs, deployment and first sign-in.

1. Prepare an existing public VCN/subnet, Identity Domain/MFA policy and accessible
   container image (app 0.4.4 or later). Private images require pull credentials.
2. Download the stack ZIP from a GitHub Release if available, or build it from a
   repository checkout:

   ```sh
   python3 apps/benchmark-control/deploy/package_resource_manager.py
   ```

3. In OCI Resource Manager, upload
   `apps/benchmark-control/dist/benchmark-resource-manager.zip`, fill the form,
   review **Plan**, then **Apply**.
4. Assign users/groups to the generated IAM integrated application.
5. Verify/trust the generated TLS certificate and open `application_url`.

The defaults create one independent Container Instance behind a Network Load
Balancer with HTTPS on **443**, private read-only configuration and **no Vault**.
Report archiving and benchmark VM provisioning permissions are optional.

The ZIP is generated, not committed. The container image is published separately;
committing this repository does not push it to OCIR. Each tenancy needs its own
valid network/IAM configuration and access to the selected image repository.

## Find the right guide

- [Required and optional fields, with examples](apps/benchmark-control/deploy/oci-resource-manager/FIELD-REFERENCE.md)
- [Deployment details, permissions and troubleshooting](apps/benchmark-control/deploy/oci-resource-manager/DEPLOYMENT-DETAILS.md)
- [Application usage and local development](apps/benchmark-control/README.md)
- [VM provisioning](apps/benchmark-control/docs/vm-provisioning.md)
- [Reports and Object Storage archive](apps/benchmark-control/docs/reporting.md)

App data uses ephemeral storage. Back up data and preserve the application
encryption key before replacing an existing container. Object Storage report
archiving does not back up the app's database or saved profiles.
