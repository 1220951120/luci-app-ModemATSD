from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]
SERVICE = ROOT / "root/etc/init.d/modem-sms-forward-AK68"
CONTROLLER = ROOT / "luasrc/controller/modem-AK68.lua"
MODEM_INIT = ROOT / "root/etc/init.d/modeminit-AK68"
BACKUP = ROOT / "root/usr/bin/modem-backup-AK68.sh"
UCI_DEFAULTS = ROOT / "root/etc/uci-defaults/99-modem-sms-forward-AK68"


class SmsForwardServiceTests(unittest.TestCase):
    def test_service_is_supervised_and_skips_an_empty_token(self):
        source = SERVICE.read_text(encoding="utf-8")
        self.assertIn("USE_PROCD=1", source)
        self.assertIn("has_token || return 0", source)
        self.assertIn(
            "procd_set_param command /usr/bin/python3 /usr/bin/smstrun-AK68.py",
            source,
        )
        self.assertIn("procd_set_param respawn", source)
        self.assertIn("PYTHONUNBUFFERED=1", source)
        self.assertIn("stop_legacy_forwarder", source)
        self.assertIn('HEALTH_FILE="/tmp/modem-sms-forward-AK68.health"', source)

    def test_controller_uses_service_lifecycle_without_nohup(self):
        source = CONTROLLER.read_text(encoding="utf-8")
        self.assertIn('SMS_FORWARD_SERVICE = "/etc/init.d/modem-sms-forward-AK68"', source)
        self.assertIn('SMS_FORWARD_SERVICE .. " restart', source)
        self.assertIn('SMS_FORWARD_SERVICE .. " stop', source)
        self.assertIn('SMS_FORWARD_SERVICE .. " running', source)
        self.assertNotIn("nohup python3 /usr/bin/smstrun-AK68.py", source)

    def test_modem_init_does_not_start_a_second_forwarder(self):
        source = MODEM_INIT.read_text(encoding="utf-8")
        self.assertNotIn("smstrun-AK68.py", source)
        self.assertNotIn("smstrun-AK68.lock", source)

    def test_backup_restore_restarts_forward_service(self):
        source = BACKUP.read_text(encoding="utf-8")
        self.assertIn("/etc/init.d/modem-sms-forward-AK68 restart", source)

    def test_upgrade_enables_the_new_service(self):
        source = UCI_DEFAULTS.read_text(encoding="utf-8")
        self.assertIn("/etc/init.d/modem-sms-forward-AK68 enable", source)


if __name__ == "__main__":
    unittest.main()
