from pathlib import Path
import shutil
import subprocess
import unittest


SCRIPT = Path(__file__).parents[1] / "root/usr/bin/pdul-AK68.lua"
LUA = shutil.which("lua")


def encode(number, message="1"):
    result = subprocess.run(
        [LUA, str(SCRIPT), "", number, message],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    length, pdu = result.stdout.strip().split("\\r", 1)
    return int(length), pdu


@unittest.skipUnless(LUA, "host Lua interpreter is unavailable")
class SmsSubmitPduTests(unittest.TestCase):
    def test_short_service_number_stays_national(self):
        _length, pdu = encode("10010")
        self.assertTrue(pdu.startswith("00010005810110F0"))

    def test_domestic_mobile_number_uses_unknown_national_toa(self):
        _length, pdu = encode("13312345678")
        self.assertTrue(pdu.startswith("0001000B813113325476F8"))

    def test_explicit_international_number_uses_international_toa(self):
        _length, pdu = encode("+8613312345678")
        self.assertTrue(pdu.startswith("0001000D91683113325476F8"))


if __name__ == "__main__":
    unittest.main()
