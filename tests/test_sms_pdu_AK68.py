import importlib.util
from pathlib import Path
import unittest
from unittest import mock


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
    @mock.patch.object(SMS, "run_modem_command")
    def test_mt5700_storage_identity_uses_hashed_iccid(self, command):
        iccid = "8986000000000000000F"
        command.return_value = f"AT^ICCID?\r\n^ICCID: {iccid}\r\nOK\r\n"

        identity = SMS.read_sms_storage_identity()

        self.assertEqual(len(identity), 64)
        self.assertNotIn(iccid, identity)
        command.assert_called_once_with("AT^ICCID?")

    @mock.patch.object(SMS, "run_modem_command")
    def test_storage_identity_falls_back_to_imsi(self, command):
        command.side_effect = [
            RuntimeError("unsupported"),
            RuntimeError("unsupported"),
            RuntimeError("unsupported"),
            "AT+CIMI\r\n460001234567890\r\nOK\r\n",
        ]

        self.assertEqual(len(SMS.read_sms_storage_identity()), 64)
        self.assertEqual(command.call_args_list[-1].args[0], "AT+CIMI")

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

    @mock.patch.object(SMS.subprocess, "run")
    def test_modem_query_requires_terminal_ok(self, run):
        run.return_value = mock.Mock(returncode=0, stdout="AT+CMGL=4\r\nERROR\r\n")
        with self.assertRaisesRegex(RuntimeError, "未返回 OK"):
            SMS.query_modem("all")

    @mock.patch.object(SMS.subprocess, "run")
    def test_modem_query_accepts_terminal_ok(self, run):
        run.return_value = mock.Mock(returncode=0, stdout="AT+CMGL=4\r\nOK\r\n")
        self.assertEqual(SMS.query_modem("all"), "AT+CMGL=4\r\nOK\r\n")

    @mock.patch.object(SMS.subprocess, "run")
    def test_sms_configuration_restores_volatile_modem_settings(self, run):
        run.return_value = mock.Mock(returncode=0, stdout="OK\r\n")
        SMS.ensure_sms_configuration(force=True)

        commands = [call.args[0][-1] for call in run.call_args_list]
        self.assertEqual(
            commands,
            [
                "AT+CMGF=0",
                'AT+CPMS="SM","SM","SM"',
                "AT+CNMI=2,1,0,2,0",
            ],
        )

    @mock.patch.object(SMS, "ensure_sms_configuration")
    @mock.patch.object(SMS.subprocess, "run")
    def test_storage_usage_is_read_from_cpms(self, run, _ensure):
        run.return_value = mock.Mock(
            returncode=0,
            stdout='AT+CPMS?\r\n+CPMS: "SM",5,50,"SM",5,50,"SM",5,50\r\nOK\r\n',
        )
        self.assertEqual(SMS.read_storage_usage(), (5, 50))

    @mock.patch.object(SMS, "ensure_sms_configuration")
    @mock.patch.object(SMS.subprocess, "run")
    def test_index_scan_recovers_messages_when_cmgl_is_empty(self, run, _ensure):
        first = make_ucs2_deliver_pdu("10086", "第一条测试短信")
        second = make_ucs2_deliver_pdu("10010", "第二条测试短信")
        run.side_effect = [
            mock.Mock(returncode=0, stdout=f"AT+CMGR=0\r\n+CMGR: 1,,0\r\n{first}\r\nOK\r\n"),
            mock.Mock(returncode=0, stdout="AT+CMGR=1\r\n+CMS ERROR: 321\r\n"),
            mock.Mock(returncode=0, stdout=f"AT+CMGR=2\r\n+CMGR: 0,,0\r\n{second}\r\nOK\r\n"),
        ]

        messages, errors = SMS.read_messages_by_index("all", (2, 5))

        self.assertEqual(errors, [])
        self.assertEqual([message["indexes"] for message in messages], [[0], [2]])
        self.assertEqual([message["content"] for message in messages], ["第一条测试短信", "第二条测试短信"])

    @mock.patch.object(SMS, "read_messages_by_index")
    @mock.patch.object(SMS, "read_storage_usage", return_value=(1, 50))
    @mock.patch.object(SMS, "query_modem", return_value="AT+CMGL=4\r\nOK\r\n")
    @mock.patch.object(SMS, "ensure_sms_configuration")
    def test_empty_cmgl_uses_index_scan(self, _ensure, _query, _usage, indexed):
        indexed.return_value = ([{"indexes": [7]}], [])
        self.assertEqual(SMS.read_messages("all"), ([{"indexes": [7]}], []))
        indexed.assert_called_once_with("all", (1, 50))


if __name__ == "__main__":
    unittest.main()
