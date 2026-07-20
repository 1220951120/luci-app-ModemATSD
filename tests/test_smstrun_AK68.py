import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "root/usr/bin/smstrun-AK68.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("smstrun_AK68", SCRIPT)
SMS_FORWARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMS_FORWARD)


class SmsForwardStateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.state_path = Path(self.directory.name) / "forward-state.json"

    def tearDown(self):
        self.directory.cleanup()

    def test_missing_state_requires_a_baseline(self):
        initialized, fingerprints = SMS_FORWARD.load_forward_state(self.state_path)
        self.assertFalse(initialized)
        self.assertEqual(fingerprints, [])

    def test_baseline_is_persistent_and_contains_no_message_content(self):
        fingerprint = "a" * 64
        messages = [{"fingerprints": [fingerprint]}]
        order = []
        seen = set()

        saved = SMS_FORWARD.establish_forward_baseline(
            messages, order, seen, self.state_path
        )
        self.assertTrue(saved)
        initialized, reloaded = SMS_FORWARD.load_forward_state(self.state_path)
        self.assertTrue(initialized)
        self.assertEqual(reloaded, [fingerprint])
        self.assertEqual(os.stat(self.state_path).st_mode & 0o777, 0o600)
        self.assertNotIn("测试短信正文", self.state_path.read_text(encoding="utf-8"))

    def test_restart_recognizes_previously_seen_segments(self):
        fingerprints = ["1" * 64, "2" * 64]
        self.assertTrue(SMS_FORWARD.save_forward_state(fingerprints, self.state_path))

        initialized, order = SMS_FORWARD.load_forward_state(self.state_path)
        self.assertTrue(initialized)
        seen = set(order)
        self.assertTrue(set(fingerprints).issubset(seen))

        SMS_FORWARD.remember_fingerprints(order, seen, fingerprints + ["3" * 64])
        self.assertEqual(order, fingerprints + ["3" * 64])

    def test_corrupt_state_fails_closed_to_a_new_baseline(self):
        self.state_path.write_text("not-json", encoding="utf-8")
        initialized, fingerprints = SMS_FORWARD.load_forward_state(self.state_path)
        self.assertFalse(initialized)
        self.assertEqual(fingerprints, [])

    def test_process_lock_rejects_a_live_owner(self):
        lock_path = Path(self.directory.name) / "forward.lock"
        self.assertTrue(SMS_FORWARD.check_lock(lock_path))
        self.assertFalse(SMS_FORWARD.check_lock(lock_path))
        self.assertEqual(os.stat(lock_path).st_mode & 0o777, 0o600)

    def test_process_lock_replaces_a_stale_pid(self):
        lock_path = Path(self.directory.name) / "forward.lock"
        lock_path.write_text("999999999", encoding="ascii")
        self.assertTrue(SMS_FORWARD.check_lock(lock_path))
        self.assertEqual(lock_path.read_text(encoding="ascii"), str(os.getpid()))


if __name__ == "__main__":
    unittest.main()
