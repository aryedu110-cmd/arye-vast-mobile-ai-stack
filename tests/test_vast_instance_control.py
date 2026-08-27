from __future__ import annotations

import importlib.util
import io
import json
import os
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "vast_instance_control", ROOT / "scripts/vast_instance_control.py"
)
vast_control = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(vast_control)


class _Response:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self):
        return json.dumps({"success": True}).encode("utf-8")


class VastInstanceControlTests(unittest.TestCase):
    def test_stop_uses_restricted_instance_credentials(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["request"] = request
            captured["timeout"] = timeout
            return _Response()

        env = {"CONTAINER_ID": "123456", "CONTAINER_API_KEY": "restricted-key"}
        with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(
            vast_control.urllib.request, "urlopen", side_effect=fake_urlopen
        ):
            result = vast_control.stop_instance()

        request = captured["request"]
        self.assertTrue(result["success"])
        self.assertEqual(request.method, "PUT")
        self.assertEqual(request.full_url, f"{vast_control.API_BASE}/instances/123456/")
        self.assertEqual(json.loads(request.data), {"state": "stopped"})
        self.assertEqual(request.get_header("Authorization"), "Bearer restricted-key")
        self.assertEqual(captured["timeout"], 20)

    def test_missing_credentials_fail_without_network(self):
        with mock.patch.dict(os.environ, {}, clear=True), self.assertRaises(RuntimeError):
            vast_control.stop_instance()

    def test_destroy_requires_exact_instance_id_and_uses_delete(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["request"] = request
            return _Response()

        env = {"CONTAINER_ID": "123456", "CONTAINER_API_KEY": "restricted-key"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            vast_control.urllib.request, "urlopen", side_effect=fake_urlopen
        ):
            with self.assertRaises(RuntimeError):
                vast_control.destroy_instance("654321")
            result = vast_control.destroy_instance("123456")

        self.assertTrue(result["success"])
        self.assertEqual(captured["request"].method, "DELETE")
        self.assertIsNone(captured["request"].data)

    def test_invalid_instance_id_fails_without_network(self):
        with mock.patch.dict(
            os.environ,
            {"CONTAINER_ID": "C.123", "CONTAINER_API_KEY": "restricted-key"},
            clear=True,
        ), self.assertRaises(RuntimeError):
            vast_control.stop_instance()


if __name__ == "__main__":
    unittest.main()
