"""Build a source-only OCI Resource Manager stack; no credentials or state included."""
from pathlib import Path
import tempfile
import zipfile

APP = Path(__file__).resolve().parents[1]
STACK = APP / "deploy" / "oci-resource-manager"


def package(destination: Path):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        archive_path = Path(temporary) / "application.zip"
        with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as archive:
            for name in ("Dockerfile", "requirements.txt"):
                archive.write(APP / name, name)
            for path in sorted((APP / "app").rglob("*")):
                if path.is_file() and path.suffix in {".py", ".js", ".css", ".html"} and "__pycache__" not in path.parts:
                    archive.write(path, path.relative_to(APP))
        with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(archive_path, "application.zip")
            for path in sorted(STACK.iterdir()):
                if path.is_file() and (path.suffix in {".tf", ".tftpl", ".py", ".yaml", ".md"} or path.name in {".terraform.lock.hcl", "terraform.tfvars.example"}):
                    archive.write(path, path.name)
            for path in sorted((STACK / "tests").rglob("*")):
                if path.is_file() and path.suffix in {".hcl", ".py"} and "__pycache__" not in path.parts:
                    archive.write(path, path.relative_to(STACK))
    print(destination)


if __name__ == "__main__":
    package(APP / "dist" / "benchmark-resource-manager.zip")
