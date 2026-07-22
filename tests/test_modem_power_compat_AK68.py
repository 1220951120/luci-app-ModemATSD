import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ModemPowerCompatibilityTests(unittest.TestCase):
    def test_atsd_only_enables_cpe_power_without_rm520n_or_modemnu313(self):
        init_script = (ROOT / "root/etc/init.d/modeminit-AK68").read_text(encoding="utf-8")
        self.assertIn(
            "if [ ! -e /usr/share/modem/rm520n.sh ] && [ ! -e /usr/bin/nu313ctl ]; then",
            init_script,
        )


if __name__ == "__main__":
    unittest.main()
