from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
os.environ["SOURCE_DIR"] = str(ROOT)
_temp = tempfile.TemporaryDirectory()
os.environ["STACK_ROOT"] = _temp.name
os.environ["MOCK_MODE"] = "1"
sys.path.insert(0, str(ROOT))

import backend  # noqa: E402


class StackTests(unittest.TestCase):
    def test_package_version(self):
        self.assertEqual((ROOT / "VERSION").read_text(encoding="utf-8").strip(), "1.2.0")

    def test_vast_docker_image_preserves_base_entrypoint(self):
        dockerfile = (ROOT / "Dockerfile.vast").read_text(encoding="utf-8")
        self.assertIn("FROM vastai/base-image:", dockerfile)
        self.assertNotIn("ENTRYPOINT [", dockerfile)
        self.assertIn("AUTO_DESTROY_MINUTES=240", dockerfile)

    def test_vast_boot_hook_runs_stack_without_replacing_access_services(self):
        hook = (ROOT / "docker" / "80-arye-ai-stack.sh").read_text(encoding="utf-8")
        self.assertIn("bash /opt/arye-vast-mobile-ai-stack/onstart.sh", hook)
        self.assertIn("Vast access services remain available", hook)
        self.assertIn('AUTO_DESTROY_MINUTES="${AUTO_DESTROY_MINUTES:-240}"', hook)

    def test_publish_workflow_has_no_embedded_registry_secret(self):
        workflow = (
            ROOT / ".github" / "workflows" / "publish-vast-image.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("secrets.GITHUB_TOKEN", workflow)
        self.assertIn("platforms: linux/amd64", workflow)
        self.assertNotIn("ghp_", workflow)
        self.assertNotIn("github_pat_", workflow)

    def test_manifest(self):
        data = json.loads((ROOT / "model_manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(data["models"]["ltx25"]["repo"], "Lightricks/LTX-2.5")
        self.assertIn("he", data["models"]["chatterbox"]["language"])
        self.assertGreaterEqual(data["recommended_disk_gb"], data["minimum_disk_gb"])

    def test_ltx_argument_validation(self):
        with self.assertRaises(ValueError):
            backend.generate_ltx("x", None, 770, 512, 121, 42)
        with self.assertRaises(ValueError):
            backend.generate_ltx("x", None, 768, 512, 120, 42)

    def test_mock_tts(self):
        path, message = backend.generate_tts("שלום", None, 0.5, 0.5)
        self.assertTrue(Path(path).is_file())
        self.assertIn("דמה", message)

    def test_status_is_mock(self):
        self.assertIn("mock", backend.status()["mode"])

    def test_manual_stop_requires_confirmation(self):
        self.assertIn("לא בוצע", backend.schedule_vast_instance_stop(False))

    def test_manual_stop_is_safe_in_mock_mode(self):
        old_id = os.environ.get("CONTAINER_ID")
        old_key = os.environ.get("CONTAINER_API_KEY")
        try:
            os.environ["CONTAINER_ID"] = "123456"
            os.environ["CONTAINER_API_KEY"] = "restricted-test-key"
            self.assertIn("דמה", backend.schedule_vast_instance_stop(True))
        finally:
            if old_id is None:
                os.environ.pop("CONTAINER_ID", None)
            else:
                os.environ["CONTAINER_ID"] = old_id
            if old_key is None:
                os.environ.pop("CONTAINER_API_KEY", None)
            else:
                os.environ["CONTAINER_API_KEY"] = old_key

    def test_manual_destroy_requires_typed_instance_id(self):
        old_id = os.environ.get("CONTAINER_ID")
        old_key = os.environ.get("CONTAINER_API_KEY")
        try:
            os.environ["CONTAINER_ID"] = "123456"
            os.environ["CONTAINER_API_KEY"] = "restricted-test-key"
            self.assertIn("אינו תואם", backend.schedule_vast_instance_destroy(True, "999999"))
            self.assertIn("דמה", backend.schedule_vast_instance_destroy(True, "123456"))
        finally:
            if old_id is None:
                os.environ.pop("CONTAINER_ID", None)
            else:
                os.environ["CONTAINER_ID"] = old_id
            if old_key is None:
                os.environ.pop("CONTAINER_API_KEY", None)
            else:
                os.environ["CONTAINER_API_KEY"] = old_key


if __name__ == "__main__":
    unittest.main()
