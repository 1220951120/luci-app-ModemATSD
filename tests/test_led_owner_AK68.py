import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / "root/usr/bin/modem-led-control-AK68.sh"


class LedOwnerTests(unittest.TestCase):
    def owner_from_flags(self, atsd, nu313):
        command = (
            f". {shlex.quote(str(CONTROL))}; "
            f"modem_led_owner_from_flags {atsd} {nu313}"
        )
        result = subprocess.run(
            ["sh", "-c", command], check=True, text=True, capture_output=True
        )
        return result.stdout.strip()

    def test_ownership_truth_table_prefers_atsd_on_ties(self):
        self.assertEqual(self.owner_from_flags(0, 0), "atsd")
        self.assertEqual(self.owner_from_flags(0, 1), "nu313")
        self.assertEqual(self.owner_from_flags(1, 0), "atsd")
        self.assertEqual(self.owner_from_flags(1, 1), "atsd")

    def test_every_atsd_led_write_checks_ownership(self):
        control = CONTROL.read_text(encoding="utf-8")
        function = control.index("modem_led_set()")
        guard = control.index("modem_led_has_control || return 3", function)
        write = control.index('echo "$value" > "$brightness"', function)
        self.assertLess(guard, write)

    def test_only_current_owner_can_write_mock_led(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            brightness = root / "leds/blue:sig1/brightness"
            brightness.parent.mkdir(parents=True)
            brightness.write_text("1\n", encoding="utf-8")
            state = root / "modem-state"
            state.write_text("AK68套件断开或未接入！\n", encoding="utf-8")
            nu313_state = root / "nu313-state"
            nu313_state.write_text("NU313-M2\nM821CU5CHE081404784\n", encoding="utf-8")
            env = os.environ.copy()
            env.update(
                MODEM_LED_STATE_FILE=str(state),
                MODEM_NU313_STATE_FILE=str(nu313_state),
                MODEM_LED_SYSFS_ROOT=str(root / "leds"),
            )
            refused = subprocess.run(
                [str(CONTROL), "0", "sig1"], env=env, text=True, capture_output=True
            )
            self.assertEqual(refused.returncode, 3)
            self.assertEqual(brightness.read_text(encoding="utf-8").strip(), "1")

            state.write_text("MT5700\n", encoding="utf-8")
            accepted = subprocess.run(
                [str(CONTROL), "0", "sig1"], env=env, text=True, capture_output=True
            )
            self.assertEqual(accepted.returncode, 0)
            self.assertEqual(brightness.read_text(encoding="utf-8").strip(), "0")

    def test_nu313_detection_reads_verified_state_file_without_adb(self):
        control = CONTROL.read_text(encoding="utf-8")
        function = control.index("modem_led_nu313_detected()")
        owner = control.index("modem_led_owner()", function)
        detection = control[function:owner]
        self.assertIn("MODEM_NU313_STATE_FILE", detection)
        self.assertNotIn("adb", detection.lower())

    def test_schedule_and_page_use_the_same_owner(self):
        schedule = (ROOT / "root/usr/bin/modem-led-schedule-AK68.sh").read_text(encoding="utf-8")
        controller = (ROOT / "luasrc/controller/modem-AK68.lua").read_text(encoding="utf-8")
        page = (ROOT / "luasrc/model/cbi/modem-led-AK68.lua").read_text(encoding="utf-8")
        self.assertIn("if ! modem_led_has_control; then", schedule)
        self.assertIn('cbi("modem-led-AK68")', controller)
        self.assertIn("当前 LED 控制权", page)
        self.assertIn("当前页面拥有 LED 控制权", page)


if __name__ == "__main__":
    unittest.main()
