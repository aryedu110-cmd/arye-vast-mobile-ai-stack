from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


def module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    loaded = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(loaded)
    return loaded


class Production18Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_safetensors_header_rejects_junk_and_accepts_minimal_index(self):
        preflight = module("runtime_preflight_test", "runtime_preflight.py")
        junk = self.root / "junk.safetensors"
        junk.write_bytes(b"junk")
        with self.assertRaises(RuntimeError):
            preflight.safetensors_header(junk)
        valid = self.root / "valid.safetensors"
        header = json.dumps({"x": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]}}).encode()
        valid.write_bytes(len(header).to_bytes(8, "little") + header + b"\0\0\0\0")
        self.assertEqual(preflight.safetensors_header(valid)["tensor_count"], 1)

    def test_queue_blocks_identity_board_and_bad_dimensions(self):
        queue = module("queue_worker_test", "queue_worker.py")
        package = self.root / "package"
        reference = package / "assets/references/C09S_messi_identity_board.jpg"
        reference.parent.mkdir(parents=True)
        reference.write_bytes(b"image")
        _, blockers = queue.validate({"mode": "image_to_video", "reference": "assets/references/C09S_messi_identity_board.jpg", "width": 960, "height": 544, "num_frames": 121, "prompt": "x"}, package)
        self.assertIn("non_scene_reference_forbidden", blockers)
        self.assertIn("two_stage_dimensions_must_be_divisible_by_64", blockers)

    def test_qc_accepts_fully_decodable_video_and_rejects_truncation(self):
        video, report = self.root / "valid.mp4", self.root / "valid.json"
        made = subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=256x256:rate=24", "-frames:v", "9", "-pix_fmt", "yuv420p", str(video)], check=False)
        self.assertEqual(made.returncode, 0)
        checked = subprocess.run([str(HERE / "qc_video.py"), str(video), "--width", "256", "--height", "256", "--fps", "24", "--frames", "9", "--report", str(report)], check=False)
        self.assertEqual(checked.returncode, 0, report.read_text() if report.exists() else "no report")
        broken, broken_report = self.root / "broken.mp4", self.root / "broken.json"
        broken.write_bytes(video.read_bytes()[:128])
        checked = subprocess.run([str(HERE / "qc_video.py"), str(broken), "--width", "256", "--height", "256", "--fps", "24", "--frames", "9", "--report", str(broken_report)], check=False)
        self.assertNotEqual(checked.returncode, 0)

    def test_health_request_requires_i2v_and_64_pixel_grid(self):
        state, project = self.root / "state", self.root / "project"
        os.environ.update(ARYE_STATE_DIR=str(state), PROJECT_ROOT=str(project), ARYE_PRIVATE_TOKEN="test-secret", ARYE_HEALTH_PORT="9876")
        health = module("health_server_test", "health_server.py")
        refs = project / "inputs/references"
        refs.mkdir(parents=True)
        reference_id = "a" * 32
        (refs / f"{reference_id}.png").write_bytes(b"image")
        with self.assertRaisesRegex(ValueError, "divisible_by_64"):
            health.validate_request({"reference_id": reference_id, "prompt": "x", "width": 960, "height": 544, "frames": 121, "seed": 1, "fps": 24})
        valid = health.validate_request({"reference_id": reference_id, "prompt": "x", "width": 1024, "height": 576, "frames": 121, "seed": 1, "fps": 24})
        self.assertEqual(valid["width"], 1024)


if __name__ == "__main__":
    unittest.main()
