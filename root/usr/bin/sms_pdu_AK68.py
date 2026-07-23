#!/usr/bin/python3

import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
import time


GSM7_BASIC = (
    "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ "
    "!\"#¤%&'()*+,-./0123456789:;<=>?"
    "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
)

GSM7_EXTENSION = {
    0x0A: "\f",
    0x14: "^",
    0x28: "{",
    0x29: "}",
    0x2F: "\\",
    0x3C: "[",
    0x3D: "~",
    0x3E: "]",
    0x40: "|",
    0x65: "€",
}

CMGL_RE = re.compile(r"^\+CMGL:\s*(\d+)\s*,\s*([^,]+)")
CMGR_RE = re.compile(r"^\+CMGR:\s*(.+)$")
CPMS_RE = re.compile(r'^\+CPMS:\s*(?:"[^"]+"\s*,\s*)?(\d+)\s*,\s*(\d+)')
HEX_RE = re.compile(r"^[0-9A-Fa-f]+$")
TERMINAL_OK_RE = re.compile(r"(?:^|[\r\n])\s*OK\s*(?:[\r\n]|$)")
TERMINAL_ERROR_RE = re.compile(
    r"(?:^|[\r\n])\s*(?:ERROR|\+CMS ERROR:.*)\s*(?:[\r\n]|$)"
)
SMS_CONFIGURATION_INTERVAL = 30
MAX_SMS_STORAGE_SLOTS = 1000

_last_sms_configuration = 0.0

SMS_IDENTITY_QUERIES = (
    (
        "AT^ICCID?",
        re.compile(r'^\s*\^ICCID:\s*"?([0-9Ff]{10,32})"?\s*$', re.MULTILINE),
    ),
    (
        "AT+QCCID",
        re.compile(r'^\s*\+QCCID:\s*"?([0-9]{10,32})"?\s*$', re.MULTILINE),
    ),
    (
        "AT+ICCID",
        re.compile(r'^\s*\+ICCID:\s*"?([0-9]{10,32})"?\s*$', re.MULTILINE),
    ),
    (
        "AT+CIMI",
        re.compile(r"^\s*([0-9]{10,20})\s*$", re.MULTILINE),
    ),
)


def swap_bcd(byte):
    return (byte & 0x0F) * 10 + ((byte >> 4) & 0x0F)


def decode_semi_octets(data, digit_count):
    digits = []
    for byte in data:
        digits.append(str(byte & 0x0F))
        high = (byte >> 4) & 0x0F
        if high != 0x0F:
            digits.append(str(high))
    return "".join(digits)[:digit_count]


def decode_gsm7(data, septet_count, start_bit=0):
    values = []
    for index in range(max(0, septet_count)):
        bit = start_bit + index * 7
        byte_index = bit // 8
        shift = bit % 8
        if byte_index >= len(data):
            break
        value = data[byte_index] >> shift
        if shift > 1 and byte_index + 1 < len(data):
            value |= data[byte_index + 1] << (8 - shift)
        values.append(value & 0x7F)

    output = []
    escaped = False
    for value in values:
        if escaped:
            output.append(GSM7_EXTENSION.get(value, "?"))
            escaped = False
        elif value == 0x1B:
            escaped = True
        elif value < len(GSM7_BASIC):
            output.append(GSM7_BASIC[value])
        else:
            output.append("?")
    if escaped:
        output.append("?")
    return "".join(output)


def decode_address(data, digit_count, toa):
    ton = (toa >> 4) & 0x07
    if ton == 0x05:
        septets = (digit_count * 4) // 7
        return decode_gsm7(data, septets)

    address = decode_semi_octets(data, digit_count)
    if ton == 0x01 and address:
        address = "+" + address
    return address


def decode_timestamp(data):
    if len(data) != 7:
        return ""
    values = [swap_bcd(byte) for byte in data[:6]]
    year, month, day, hour, minute, second = values
    if not (1 <= month <= 12 and 1 <= day <= 31 and hour <= 23 and minute <= 59 and second <= 59):
        return ""
    # SCTS already contains the sender's local wall-clock time. The seventh
    # octet describes its UTC offset and must not be added to the clock again.
    return f"20{year:02d}-{month:02d}-{day:02d} {hour:02d}:{minute:02d}:{second:02d}"


def parse_udh(user_data):
    if not user_data:
        return 0, None
    header_size = user_data[0] + 1
    if header_size > len(user_data):
        raise ValueError("短信分段头长度无效")

    concatenation = None
    position = 1
    while position + 1 < header_size:
        identifier = user_data[position]
        length = user_data[position + 1]
        start = position + 2
        end = start + length
        if end > header_size:
            raise ValueError("短信分段头内容不完整")
        value = user_data[start:end]
        if identifier == 0x00 and length == 3:
            concatenation = {"reference": value[0], "total": value[1], "sequence": value[2]}
        elif identifier == 0x08 and length == 4:
            concatenation = {
                "reference": (value[0] << 8) | value[1],
                "total": value[2],
                "sequence": value[3],
            }
        position = end
    return header_size, concatenation


def decode_user_data(data, dcs, user_length, has_udh):
    header_size = 0
    concatenation = None
    if has_udh:
        header_size, concatenation = parse_udh(data)

    alphabet = dcs & 0x0C
    if alphabet == 0x08:
        payload = data[header_size:user_length]
        if len(payload) % 2:
            payload = payload[:-1]
        text = payload.decode("utf-16-be", errors="replace")
    elif alphabet == 0x04:
        text = data[header_size:user_length].decode("latin-1", errors="replace")
    else:
        if has_udh:
            header_septets = math.ceil(header_size * 8 / 7)
            text = decode_gsm7(data, user_length - header_septets, header_septets * 7)
        else:
            text = decode_gsm7(data, user_length)
    return text.rstrip("\x00"), concatenation


def decode_pdu(pdu):
    if not HEX_RE.fullmatch(pdu) or len(pdu) % 2:
        raise ValueError("PDU 不是有效的十六进制数据")
    raw = bytes.fromhex(pdu)
    if len(raw) < 2:
        raise ValueError("PDU 数据过短")

    position = 1 + raw[0]
    if position >= len(raw):
        raise ValueError("短信中心地址长度无效")

    first_octet = raw[position]
    position += 1
    if first_octet & 0x03 != 0:
        raise ValueError("当前仅支持接收短信 PDU")

    address_length = raw[position]
    position += 1
    toa = raw[position]
    position += 1
    address_octets = (address_length + 1) // 2
    address_data = raw[position:position + address_octets]
    if len(address_data) != address_octets:
        raise ValueError("发件人地址不完整")
    position += address_octets
    sender = decode_address(address_data, address_length, toa)

    if position + 10 > len(raw):
        raise ValueError("PDU 头部不完整")
    position += 1  # TP-PID
    dcs = raw[position]
    position += 1
    timestamp = decode_timestamp(raw[position:position + 7])
    position += 7
    user_length = raw[position]
    position += 1
    user_data = raw[position:]

    text, concatenation = decode_user_data(user_data, dcs, user_length, bool(first_octet & 0x40))
    return {
        "sender": sender,
        "timestamp": timestamp,
        "content": text,
        "concat": concatenation,
    }


def parse_status(value):
    value = value.strip().strip('"')
    names = {
        "REC UNREAD": 0,
        "REC READ": 1,
        "STO UNSENT": 2,
        "STO SENT": 3,
        "ALL": 4,
    }
    try:
        return int(value)
    except ValueError:
        return names.get(value.upper(), -1)


def parse_cmgl(output):
    lines = [line.strip() for line in output.replace("\r", "\n").split("\n")]
    records = []
    errors = []
    position = 0
    while position < len(lines):
        match = CMGL_RE.match(lines[position])
        if not match:
            position += 1
            continue

        index = int(match.group(1))
        status = parse_status(match.group(2))
        position += 1
        while position < len(lines) and not lines[position]:
            position += 1
        if position >= len(lines) or not HEX_RE.fullmatch(lines[position]) or len(lines[position]) % 2:
            errors.append(f"第 {index} 条短信缺少有效 PDU")
            continue

        pdu = lines[position].upper()
        try:
            decoded = decode_pdu(pdu)
            decoded.update({
                "index": index,
                "status": status,
                "pdu": pdu,
                "fingerprint": hashlib.sha256(pdu.encode("ascii")).hexdigest(),
            })
            records.append(decoded)
        except ValueError as error:
            errors.append(f"第 {index} 条短信解析失败：{error}")
        position += 1
    return records, errors


def merge_messages(records):
    groups = {}
    order = []
    for record in records:
        concat = record.get("concat")
        if concat:
            key = (
                record["sender"],
                record["timestamp"],
                concat["reference"],
                concat["total"],
            )
        else:
            key = ("single", record["index"], record["fingerprint"])
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(record)

    messages = []
    for key in order:
        parts = groups[key]
        concat = parts[0].get("concat")
        if concat:
            by_sequence = {}
            for part in parts:
                by_sequence.setdefault(part["concat"]["sequence"], part)
            total = concat["total"]
            complete = total > 0 and all(sequence in by_sequence for sequence in range(1, total + 1))
            ordered = [by_sequence[sequence] for sequence in sorted(by_sequence)]
        else:
            complete = True
            total = 1
            ordered = parts

        messages.append({
            "indexes": sorted(part["index"] for part in ordered),
            "statuses": [part["status"] for part in ordered],
            "sender": ordered[0]["sender"],
            "timestamp": ordered[0]["timestamp"],
            "content": "".join(part["content"] for part in ordered),
            "complete": complete,
            "segment_count": total,
            "fingerprints": [part["fingerprint"] for part in ordered],
        })
    messages.sort(key=lambda message: min(message["indexes"]))
    return messages


def run_modem_command(command, require_ok=True):
    process = subprocess.run(
        ["/usr/bin/atsd_tools_cli", "-i", "cpe", "-c", command],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
        check=False,
    )
    if process.returncode != 0:
        raise RuntimeError(f"短信 AT 命令失败（{command}，退出码 {process.returncode}）")
    if require_ok and not TERMINAL_OK_RE.search(process.stdout):
        raise RuntimeError(f"短信 AT 命令失败（{command}，模组未返回 OK）")
    return process.stdout


def ensure_sms_configuration(force=False):
    global _last_sms_configuration

    now = time.monotonic()
    if not force and now - _last_sms_configuration < SMS_CONFIGURATION_INTERVAL:
        return

    # MT5700 resets these volatile settings after a module/SIM restart.  Keep
    # restoring them so a late modem initialization cannot silently disable
    # SMS reception after the procd service has already started.
    for command in (
        "AT+CMGF=0",
        'AT+CPMS="SM","SM","SM"',
        "AT+CNMI=2,1,0,2,0",
    ):
        run_modem_command(command)
    _last_sms_configuration = now


def read_sms_storage_identity():
    errors = []
    for command, pattern in SMS_IDENTITY_QUERIES:
        try:
            output = run_modem_command(command)
        except RuntimeError as error:
            errors.append(str(error))
            continue

        match = pattern.search(output)
        if not match:
            errors.append(f"{command} 未返回可识别的 SIM 身份")
            continue

        # The MT5700M-CN manual specifies AT^ICCID? for the active SIM.
        # Persist only a one-way identifier; never write ICCID/IMSI plaintext
        # to forwarding state or logs.
        identity = match.group(1).upper().rstrip("F")
        return hashlib.sha256(f"sms-storage:{identity}".encode("ascii")).hexdigest()

    detail = "；".join(errors[-2:]) if errors else "模组未返回 SIM 身份"
    raise RuntimeError(f"无法确认当前短信存储身份（{detail}）")


def read_storage_usage():
    ensure_sms_configuration()
    output = run_modem_command("AT+CPMS?")
    for line in output.replace("\r", "\n").split("\n"):
        match = CPMS_RE.match(line.strip())
        if match:
            used, total = int(match.group(1)), int(match.group(2))
            if total <= 0 or total > MAX_SMS_STORAGE_SLOTS or used < 0 or used > total:
                break
            return used, total
    raise RuntimeError("读取短信存储容量失败（CPMS 返回格式无效）")


def cmgr_to_cmgl(index, output):
    lines = [line.strip() for line in output.replace("\r", "\n").split("\n")]
    for position, line in enumerate(lines):
        match = CMGR_RE.match(line)
        if not match:
            continue
        payload_position = position + 1
        while payload_position < len(lines) and not lines[payload_position]:
            payload_position += 1
        if payload_position >= len(lines) or not HEX_RE.fullmatch(lines[payload_position]):
            raise RuntimeError(f"第 {index} 个短信槽位没有返回有效 PDU")
        if len(lines[payload_position]) % 2:
            raise RuntimeError(f"第 {index} 个短信槽位返回了奇数长度 PDU")
        if not TERMINAL_OK_RE.search(output):
            raise RuntimeError(f"第 {index} 个短信槽位读取未正常结束")
        return f"+CMGL: {index},{match.group(1)}\r\n{lines[payload_position]}\r\n"
    return None


def query_message_slots(usage=None):
    ensure_sms_configuration()
    used, total = usage if usage is not None else read_storage_usage()
    if used == 0:
        return "OK\r\n"

    records = []
    for index in range(total):
        output = run_modem_command(f"AT+CMGR={index}", require_ok=False)
        record = cmgr_to_cmgl(index, output)
        if record is not None:
            records.append(record)
            if len(records) >= used:
                break
        elif not TERMINAL_ERROR_RE.search(output):
            raise RuntimeError(f"第 {index} 个短信槽位返回了无法识别的结果")

    if len(records) != used:
        raise RuntimeError(f"短信存储报告 {used} 条，实际只读取到 {len(records)} 条")
    return "".join(records) + "OK\r\n"


def query_modem(status):
    command = "AT+CMGL=0" if status == "unread" else "AT+CMGL=4"
    return run_modem_command(command)


def parse_messages(output, status="all"):
    records, errors = parse_cmgl(output)
    if status == "unread":
        records = [record for record in records if record["status"] == 0]
    return merge_messages(records), errors


def read_messages_by_index(status="all", usage=None):
    return parse_messages(query_message_slots(usage), status)


def read_messages(status="all", input_text=None):
    if input_text is not None:
        return parse_messages(input_text, status)

    ensure_sms_configuration()
    output = query_modem(status)
    messages, errors = parse_messages(output, status)
    if messages or errors:
        return messages, errors

    usage = read_storage_usage()
    if usage[0] == 0:
        return [], []
    return read_messages_by_index(status, usage)


def format_timestamp(timestamp):
    match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2}) (\d{2}:\d{2}:\d{2})", timestamp or "")
    if not match:
        return timestamp or "未知"
    return f"{match.group(2)}/{match.group(3)}/{match.group(1)[2:]} {match.group(4)}"


def format_message(message):
    indexes = ",".join(str(index) for index in message["indexes"])
    content = message["content"]
    if not message["complete"]:
        content += f"\n[长短信尚未收全：已收到 {len(message['indexes'])}/{message['segment_count']} 段]"
    return (
        f"第{indexes}条短信\n"
        f"发件人:{message['sender']}\n"
        f"发件时间:{format_timestamp(message['timestamp'])}\n"
        f"{content}"
    )


def main():
    parser = argparse.ArgumentParser(description="读取并解码 MT5700 PDU 短信")
    parser.add_argument("--status", choices=("all", "unread"), default="all")
    parser.add_argument("--format", choices=("json", "text"), default="json")
    parser.add_argument("--input", help="从文件读取 AT+CMGL 输出，- 表示标准输入")
    args = parser.parse_args()

    try:
        input_text = None
        if args.input:
            if args.input == "-":
                input_text = sys.stdin.read()
            else:
                with open(args.input, "r", encoding="utf-8") as handle:
                    input_text = handle.read()
        messages, errors = read_messages(args.status, input_text)
        if args.format == "text":
            separator = "\n------------------------------------------------------\n"
            print(separator.join(format_message(message) for message in messages))
        else:
            print(json.dumps({"success": True, "messages": messages, "errors": errors}, ensure_ascii=False))
    except Exception as error:
        if args.format == "json":
            print(json.dumps({"success": False, "messages": [], "errors": [str(error)]}, ensure_ascii=False))
        else:
            print(f"读取短信失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
