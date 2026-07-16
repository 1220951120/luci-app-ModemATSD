import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).parents[1] / "root/usr/bin/sms_pdu_AK68.py"
SPEC = importlib.util.spec_from_file_location("sms_pdu_AK68", SCRIPT)
SMS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMS)


def encode_semi_octets(value):
    if len(value) % 2:
        value += "F"
    return bytes(int(value[index + 1] + value[index], 16) for index in range(0, len(value), 2))


def encode_scts(timestamp="260102030405", timezone="32"):
    return encode_semi_octets(timestamp + timezone)


def make_ucs2_deliver_pdu(sender, content, sequence=None, total=None, reference=0x42):
    address = encode_semi_octets(sender)
    user_data = content.encode("utf-16-be")
    first_octet = 0x00
    if sequence is not None:
        first_octet = 0x40
        user_data = bytes((0x05, 0x00, 0x03, reference, total, sequence)) + user_data

    pdu = bytearray((0x00, first_octet, len(sender), 0xA1))
    pdu.extend(address)
    pdu.extend((0x00, 0x08))
    pdu.extend(encode_scts())
    pdu.append(len(user_data))
    pdu.extend(user_data)
    return pdu.hex().upper()


def cmgl_output(items):
    return "\n".join(f"+CMGL: {index},1,,0\n{pdu}" for index, pdu in items)


class SmsPduTests(unittest.TestCase):
    def test_single_ucs2_message_and_scts(self):
        content = "测试验证码：123456，请勿泄露。"
        pdu = make_ucs2_deliver_pdu("10086", content)
        messages, errors = SMS.read_messages(input_text=cmgl_output([(9, pdu)]))

        self.assertEqual(errors, [])
        self.assertEqual(len(messages), 1)
        message = messages[0]
        self.assertEqual(message["sender"], "10086")
        self.assertEqual(message["timestamp"], "2026-01-02 03:04:05")
        self.assertEqual(message["content"], content)

    def test_multipart_message_is_reordered_and_merged(self):
        parts = [
            "这是虚构测试长短信的第一段。",
            "这是第二段，用于验证乱序重组。",
            "这是第三段，不包含真实用户数据。",
            "这是第四段，用于检查分段元数据。",
            "这是最后一段，测试结束。",
        ]
        # Deliberately store the five segments out of order.
        order = ((14, 4), (11, 1), (15, 5), (13, 3), (12, 2))
        records = [
            (index, make_ucs2_deliver_pdu("10086", parts[sequence - 1], sequence, 5))
            for index, sequence in order
        ]
        messages, errors = SMS.read_messages(input_text=cmgl_output(records))

        self.assertEqual(errors, [])
        self.assertEqual(len(messages), 1)
        message = messages[0]
        self.assertTrue(message["complete"])
        self.assertEqual(message["segment_count"], 5)
        self.assertEqual(message["sender"], "10086")
        self.assertEqual(message["timestamp"], "2026-01-02 03:04:05")
        self.assertEqual(message["content"], "".join(parts))
        self.assertNotIn("Reference number", message["content"])
        self.assertNotIn("SMS segment", message["content"])


if __name__ == "__main__":
    unittest.main()
