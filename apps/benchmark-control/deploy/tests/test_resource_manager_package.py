import importlib.util
import io
from pathlib import Path
import re
import tempfile
import unittest
import zipfile

DEPLOY = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package_resource_manager", DEPLOY / "package_resource_manager.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackageTests(unittest.TestCase):
    def test_self_contained_stack_and_build_context_without_local_state(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "stack.zip"
            packager.package(target)
            with zipfile.ZipFile(target) as archive:
                names = set(archive.namelist())
                self.assertTrue({"schema.yaml", "application.tf", "network.tf", "endpoint.tf", "identity.tf", "runtime.py",
                                 "terraform.tfvars.example", ".terraform.lock.hcl", "tests/security.tftest.hcl",
                                 "tests/test_runtime.py", "application.zip"}.issubset(names))
                for name in names:
                    self.assertFalse(any(part in name for part in (".local/", ".terraform/", "tfstate", "oidc_pilot", "restricted_pilot")))
                self.assertFalse({"bootstrap.py", "cloud-init.yaml.tftpl", "load-balancer.tf"} & names)
                variables = set(re.findall(r'variable "([^"]+)"', archive.read("variables.tf").decode()))
                # Every input has a Resource Manager form definition.
                schema = archive.read("schema.yaml").decode().split('\nvariables:\n', 1)[1]
                self.assertEqual(variables, set(re.findall(r'^  ([a-z_]+):$', schema, re.M)))
                # Ensure the published ZIP contains OCI selectors with their required scopes.
                def field(name):
                    return re.search(rf"^  {name}:\n(.*?)(?=^  [a-z_]+:|\Z)", schema, re.M | re.S).group(1)
                for name, kind in {"region": "oci:identity:region:name", "availability_domain": "oci:identity:availabilitydomain:name", "vcn_ocid": "oci:core:vcn:id", "subnet_ocid": "oci:core:subnet:id"}.items():
                    self.assertIn(f"type: {kind}", field(name))
                self.assertIn("compartmentId: ${vcn_compartment_ocid}", field("vcn_ocid"))
                self.assertIn("vcnId: ${vcn_ocid}", field("subnet_ocid"))
                self.assertIn("compartmentId: ${subnet_compartment_ocid}", field("subnet_ocid"))
                self.assertIn("hidePrivateSubnet: true", field("subnet_ocid"))
                self.assertIn("default: ${session.region}", field("region"))
                for name in ("allowed_client_cidrs", "benchmark_target_cidrs"):
                    self.assertIn("default: []", field(name))
                for name in ("allowed_client_cidrs_text", "benchmark_target_cidrs_text", "benchmark_compartment_ocids", "benchmark_network_compartment_ocids"):
                    self.assertIn("type: text", field(name))
                    self.assertIn("multiline: true", field(name))
                with zipfile.ZipFile(io.BytesIO(archive.read("application.zip"))) as source:
                    self.assertTrue({"Dockerfile", "requirements.txt", "app/main.py", "app/iam_auth.py", "app/config.py",
                                     "app/templates/index.html", "app/templates/login.html", "app/static/login.css"}.issubset(source.namelist()))
                    self.assertNotIn("app/static/index.html", source.namelist())
                    self.assertFalse(any(name.endswith((".db", ".pem", ".key", ".env")) for name in source.namelist()))


if __name__ == "__main__":
    unittest.main()
