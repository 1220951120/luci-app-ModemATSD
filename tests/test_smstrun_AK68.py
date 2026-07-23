import importlib.util
from datetime import datetime, timedelta
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
        self.storage_a = "a" * 64
        self.storage_b = "b" * 64

    def tearDown(self):
        self.directory.cleanup()

    def test_missing_state_requires_a_baseline(self):
        initialized, fingerprints = SMS_FORWARD.load_forward_state(
            self.storage_a, self.state_path
        )
        self.assertFalse(initialized)
        self.assertEqual(fingerprints, [])

    def test_baseline_is_persistent_and_contains_no_message_content(self):
        fingerprint = "a" * 64
        messages = [{"fingerprints": [fingerprint]}]
        order = []
        seen = set()

        saved = SMS_FORWARD.establish_forward_baseline(
            self.storage_a,
            messages,
            order,
            seen,
            path=self.state_path,
        )
        self.assertTrue(saved)
        initialized, reloaded = SMS_FORWARD.load_forward_state(
            self.storage_a, self.state_path
        )
        self.assertTrue(initialized)
        self.assertEqual(reloaded, [fingerprint])
        self.assertEqual(os.stat(self.state_path).st_mode & 0o777, 0o600)
        self.assertNotIn("测试短信正文", self.state_path.read_text(encoding="utf-8"))

    def test_restart_recognizes_previously_seen_segments(self):
        fingerprints = ["1" * 64, "2" * 64]
        self.assertTrue(
            SMS_FORWARD.save_forward_state(
                self.storage_a, fingerprints, path=self.state_path
            )
        )

        initialized, order = SMS_FORWARD.load_forward_state(
            self.storage_a, self.state_path
        )
        self.assertTrue(initialized)
        seen = set(order)
        self.assertTrue(set(fingerprints).issubset(seen))

        SMS_FORWARD.remember_fingerprints(order, seen, fingerprints + ["3" * 64])
        self.assertEqual(order, fingerprints + ["3" * 64])

    def test_corrupt_state_fails_closed_to_a_new_baseline(self):
        self.state_path.write_text("not-json", encoding="utf-8")
        initialized, fingerprints = SMS_FORWARD.load_forward_state(
            self.storage_a, self.state_path
        )
        self.assertFalse(initialized)
        self.assertEqual(fingerprints, [])

    def test_sim_profiles_do_not_share_history(self):
        old_external_sms = ["1" * 64, "2" * 64, "3" * 64]
        self.assertTrue(
            SMS_FORWARD.save_forward_state(
                self.storage_a, [], path=self.state_path
            )
        )
        self.assertTrue(
            SMS_FORWARD.save_forward_state(
                self.storage_b, old_external_sms, path=self.state_path
            )
        )

        initialized_a, fingerprints_a = SMS_FORWARD.load_forward_state(
            self.storage_a, self.state_path
        )
        initialized_b, fingerprints_b = SMS_FORWARD.load_forward_state(
            self.storage_b, self.state_path
        )

        self.assertTrue(initialized_a)
        self.assertEqual(fingerprints_a, [])
        self.assertTrue(initialized_b)
        self.assertEqual(fingerprints_b, old_external_sms)

    def test_empty_baseline_requires_three_clean_confirmations(self):
        confirmations = 0
        ready_values = []
        for _ in range(3):
            confirmations, ready = SMS_FORWARD.baseline_confirmation(
                0, [], confirmations
            )
            ready_values.append(ready)

        self.assertEqual(ready_values, [False, False, True])

    def test_v1_state_fails_closed_instead_of_crossing_sim_profiles(self):
        self.state_path.write_text(
            '{"version":1,"fingerprints":["' + "1" * 64 + '"]}',
            encoding="utf-8",
        )
        initialized, fingerprints = SMS_FORWARD.load_forward_state(
            self.storage_b, self.state_path
        )
        self.assertFalse(initialized)
        self.assertEqual(fingerprints, [])

    def test_forward_window_accepts_messages_up_to_24_hours_old(self):
        now = datetime(2026, 7, 24, 12, 0, 0)
        allowed, error = SMS_FORWARD.forwarding_timestamp_allowed(
            (now - timedelta(hours=24)).strftime(SMS_FORWARD.SMS_TIMESTAMP_FORMAT),
            now=now,
        )
        self.assertTrue(allowed)
        self.assertIsNone(error)

    def test_forward_window_rejects_messages_older_than_24_hours(self):
        now = datetime(2026, 7, 24, 12, 0, 0)
        allowed, error = SMS_FORWARD.forwarding_timestamp_allowed(
            (now - timedelta(hours=24, seconds=1)).strftime(
                SMS_FORWARD.SMS_TIMESTAMP_FORMAT
            ),
            now=now,
        )
        self.assertFalse(allowed)
        self.assertIn("超过 24 小时", error)

    def test_forward_window_rejects_missing_or_invalid_timestamp(self):
        now = datetime(2026, 7, 24, 12, 0, 0)
        for timestamp in ("", None, "not-a-time", "2026-02-30 12:00:00"):
            with self.subTest(timestamp=timestamp):
                allowed, error = SMS_FORWARD.forwarding_timestamp_allowed(
                    timestamp, now=now
                )
                self.assertFalse(allowed)
                self.assertIn("无效", error)

    def test_forward_window_tolerates_only_small_future_clock_skew(self):
        now = datetime(2026, 7, 24, 12, 0, 0)
        within_tolerance = (now + timedelta(minutes=5)).strftime(
            SMS_FORWARD.SMS_TIMESTAMP_FORMAT
        )
        outside_tolerance = (now + timedelta(minutes=5, seconds=1)).strftime(
            SMS_FORWARD.SMS_TIMESTAMP_FORMAT
        )

        self.assertTrue(
            SMS_FORWARD.forwarding_timestamp_allowed(
                within_tolerance, now=now
            )[0]
        )
        allowed, error = SMS_FORWARD.forwarding_timestamp_allowed(
            outside_tolerance, now=now
        )
        self.assertFalse(allowed)
        self.assertIn("晚于", error)

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

    def test_health_file_contains_no_sms_content(self):
        health_path = Path(self.directory.name) / "forward-health.json"
        SMS_FORWARD.save_forward_health(True, storage_used=3, scanned=True, path=health_path)
        health = health_path.read_text(encoding="utf-8")
        self.assertIn('"storage_used":3', health)
        self.assertIn('"ready":true', health)
        self.assertNotIn("短信正文", health)
        self.assertEqual(os.stat(health_path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
