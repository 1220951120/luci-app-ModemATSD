import subprocess
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "root"
    / "usr"
    / "bin"
    / "modem-auto-schedule-AK68.sh"
)


class ModemLockScheduleTests(unittest.TestCase):
    rules = (
        "1,07:00,01:00,nr_sa_cell,0,78,640000,321;"
        "1,01:00,05:00,nr_sa_band,1,78,0,0"
    )

    def run_script(self, *args):
        return subprocess.run(
            [str(SCRIPT), *args],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    def test_adjacent_cross_midnight_rules_are_valid(self):
        result = self.run_script("--validate", self.rules)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout.strip(), "OK")

    def test_boundary_switches_directly_between_rules(self):
        expected = {
            "00:59": "rule:1,",
            "01:00": "rule:2,",
            "04:59": "rule:2,",
            "05:00": "auto",
            "06:59": "auto",
            "07:00": "rule:1,",
        }
        for current_time, prefix in expected.items():
            with self.subTest(current_time=current_time):
                result = self.run_script("--select", self.rules, current_time)
                self.assertEqual(result.returncode, 0, result.stdout)
                if prefix == "auto":
                    self.assertEqual(result.stdout.strip(), prefix)
                else:
                    self.assertTrue(result.stdout.startswith(prefix), result.stdout)

    def test_overlapping_enabled_rules_are_rejected(self):
        rules = (
            "1,07:00,01:00,nr_sa_cell,0,78,640000,321;"
            "1,00:30,05:00,nr_sa_band,1,78,0,0"
        )
        result = self.run_script("--validate", rules)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("重叠", result.stdout)

    def test_disabled_rule_does_not_cause_overlap(self):
        rules = (
            "1,07:00,01:00,nr_sa_cell,0,78,640000,321;"
            "0,00:30,05:00,nr_sa_band,1,78,0,0"
        )
        result = self.run_script("--validate", rules)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_out_of_range_nr_pci_is_rejected(self):
        result = self.run_script(
            "--validate", "1,07:00,01:00,nr_sa_cell,0,78,640000,1008"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0-1007", result.stdout)

    def test_midnight_to_midnight_means_all_day(self):
        rule = "1,00:00,00:00,lte_band,1,3,0,0"
        result = self.run_script("--validate", rule)
        self.assertEqual(result.returncode, 0, result.stdout)
        for current_time in ("00:00", "12:34", "23:59"):
            with self.subTest(current_time=current_time):
                selected = self.run_script("--select", rule, current_time)
                self.assertEqual(selected.returncode, 0, selected.stdout)
                self.assertTrue(selected.stdout.startswith("rule:1,"), selected.stdout)

    def test_other_equal_times_are_rejected(self):
        result = self.run_script(
            "--validate", "1,07:00,07:00,lte_band,0,3,0,0"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("00:00", result.stdout)

    def test_all_day_rule_overlaps_every_other_enabled_rule(self):
        rules = (
            "1,00:00,00:00,lte_band,0,3,0,0;"
            "1,12:00,13:00,nr_sa_band,0,78,0,0"
        )
        result = self.run_script("--validate", rules)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("重叠", result.stdout)

    def test_mobility_must_be_zero_or_one(self):
        result = self.run_script(
            "--validate", "1,07:00,08:00,lte_band,2,3,0,0"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("重选与切换", result.stdout)

    def test_r22_rule_format_is_not_accepted(self):
        result = self.run_script(
            "--validate", "1,07:00,01:00,nr_sa_cell,78,640000,321"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("格式错误", result.stdout)


if __name__ == "__main__":
    unittest.main()
