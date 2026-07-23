import json
import os
import re
import time
import requests
from datetime import datetime

import sms_pdu_AK68


FORWARD_STATE_PATH = "/etc/modem-sms-forward-AK68.state"
FORWARD_STATE_VERSION = 2
MAX_SAVED_FINGERPRINTS = 4096
MAX_SAVED_STORAGE_PROFILES = 8
EMPTY_BASELINE_CONFIRMATIONS = 3
FORWARD_HEALTH_PATH = "/tmp/modem-sms-forward-AK68.health"
FULL_SMS_SCAN_INTERVAL = 60
POLL_INTERVAL = 5
FORWARD_MAX_MESSAGE_AGE = 24 * 60 * 60
FORWARD_FUTURE_TOLERANCE = 5 * 60
SMS_TIMESTAMP_FORMAT = "%Y-%m-%d %H:%M:%S"


def normalize_fingerprints(values):
    fingerprints = []
    seen = set()
    for value in values if isinstance(values, list) else []:
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            continue
        if value in seen:
            continue
        seen.add(value)
        fingerprints.append(value)
    return fingerprints[-MAX_SAVED_FINGERPRINTS:]


def read_forward_state(path=FORWARD_STATE_PATH):
    try:
        with open(path, "r", encoding="utf-8") as file:
            data = json.load(file)
        if data.get("version") != FORWARD_STATE_VERSION:
            raise ValueError("状态版本不受支持")

        raw_storages = data.get("storages")
        if not isinstance(raw_storages, dict):
            raise ValueError("短信存储状态格式无效")

        storages = {}
        for storage_identity, profile in raw_storages.items():
            if not isinstance(storage_identity, str) or not re.fullmatch(
                r"[0-9a-f]{64}", storage_identity
            ):
                continue
            if not isinstance(profile, dict):
                continue
            storages[storage_identity] = {
                "initialized": profile.get("initialized") is True,
                "fingerprints": normalize_fingerprints(profile.get("fingerprints")),
            }
        return storages
    except FileNotFoundError:
        return {}
    except Exception as error:
        print(f"读取短信转发去重状态失败，将重新建立基线: {error}")
        return {}


def load_forward_state(storage_identity, path=FORWARD_STATE_PATH):
    profile = read_forward_state(path).get(storage_identity)
    if not profile:
        return False, []
    return profile["initialized"], profile["fingerprints"]


def save_forward_state(
    storage_identity,
    fingerprints,
    initialized=True,
    path=FORWARD_STATE_PATH,
):
    temporary_path = f"{path}.tmp.{os.getpid()}"
    storages = read_forward_state(path)
    storages.pop(storage_identity, None)
    storages[storage_identity] = {
        "initialized": bool(initialized),
        "fingerprints": normalize_fingerprints(list(fingerprints)),
    }
    while len(storages) > MAX_SAVED_STORAGE_PROFILES:
        del storages[next(iter(storages))]

    data = {
        "version": FORWARD_STATE_VERSION,
        "storages": storages,
    }
    try:
        with open(temporary_path, "w", encoding="utf-8") as file:
            json.dump(data, file, ensure_ascii=True, separators=(",", ":"))
            file.flush()
            os.fsync(file.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
        return True
    except Exception as error:
        print(f"保存短信转发去重状态失败: {error}")
        try:
            os.remove(temporary_path)
        except FileNotFoundError:
            pass
        return False


def save_forward_health(
    ok,
    storage_used=None,
    scanned=False,
    ready=True,
    error=None,
    path=FORWARD_HEALTH_PATH,
):
    temporary_path = f"{path}.tmp.{os.getpid()}"
    data = {
        "version": 1,
        "timestamp": int(time.time()),
        "ok": bool(ok),
        "storage_used": storage_used,
        "scanned": bool(scanned),
        "ready": bool(ready),
        "error": str(error)[:500] if error else None,
    }
    try:
        with open(temporary_path, "w", encoding="utf-8") as file:
            json.dump(data, file, ensure_ascii=True, separators=(",", ":"))
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    except OSError as health_error:
        print(f"保存短信转发健康状态失败: {health_error}")
        try:
            os.remove(temporary_path)
        except FileNotFoundError:
            pass


def remember_fingerprints(fingerprint_order, seen_fingerprints, fingerprints):
    for fingerprint in fingerprints:
        if fingerprint in seen_fingerprints:
            continue
        seen_fingerprints.add(fingerprint)
        fingerprint_order.append(fingerprint)

    overflow = len(fingerprint_order) - MAX_SAVED_FINGERPRINTS
    if overflow > 0:
        expired = fingerprint_order[:overflow]
        del fingerprint_order[:overflow]
        seen_fingerprints.difference_update(expired)


def establish_forward_baseline(
    storage_identity,
    messages,
    fingerprint_order,
    seen_fingerprints,
    initialized=True,
    path=FORWARD_STATE_PATH,
):
    for sms in messages:
        remember_fingerprints(
            fingerprint_order,
            seen_fingerprints,
            sms["fingerprints"],
        )
    return save_forward_state(
        storage_identity,
        fingerprint_order,
        initialized=initialized,
        path=path,
    )


def baseline_confirmation(storage_used, errors, empty_confirmations):
    if errors:
        return 0, False
    if storage_used > 0:
        return EMPTY_BASELINE_CONFIRMATIONS, True
    empty_confirmations += 1
    return (
        empty_confirmations,
        empty_confirmations >= EMPTY_BASELINE_CONFIRMATIONS,
    )


def forwarding_timestamp_allowed(timestamp, now=None):
    try:
        message_time = datetime.strptime(timestamp or "", SMS_TIMESTAMP_FORMAT)
    except (TypeError, ValueError):
        return False, "短信时间缺失或格式无效"

    current_time = now or datetime.now()
    age_seconds = (current_time - message_time).total_seconds()
    if age_seconds < -FORWARD_FUTURE_TOLERANCE:
        return False, "短信时间明显晚于路由器当前时间"
    if age_seconds > FORWARD_MAX_MESSAGE_AGE:
        return False, "短信时间已超过 24 小时"
    return True, None


def read_token_from_config():
    config_path = "/usr/bin/smstrun-AK68.conf"
    try:
        with open(config_path, 'r') as file:
            token = file.read().strip()  
            if not token:  
                print("未填写token，程序已退出！")
                exit()
            return token
    except FileNotFoundError:
        print("未找到配置文件，程序已退出！")
        exit()

def read_title_from_config():
    title_path = "/usr/bin/smstrun-title-AK68.conf"
    try:
        with open(title_path, 'r') as file:
            title = file.read().strip()  
            if not title:
                title = "CPE短信转发标题未定义"
            return title
    except FileNotFoundError:
        return "CPE短信转发标题未定义"

def write_summary_to_file(count, out):
    summary_path = "/tmp/smstrunsum-AK68.conf"
    current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    try:
        with open(summary_path, 'a') as file:  
            file.write(f"本次转发时间: {current_time}\n") 
            file.write(f"已完成: {count}次短信转发\n") 
            file.write(f"转发内容:\n\n{out}\n") 
            file.write("\n")
    except Exception as e:
        print(f"写入文件失败: {e}")

def lock_owner_running(lock_file):
    try:
        with open(lock_file, "r", encoding="ascii") as file:
            pid = int(file.read().strip())
    except (FileNotFoundError, OSError, TypeError, ValueError):
        return False

    if pid <= 1:
        return False
    if pid == os.getpid():
        return True

    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

    try:
        with open(f"/proc/{pid}/cmdline", "rb") as file:
            arguments = file.read().split(b"\0")
        return any(argument.endswith(b"/smstrun-AK68.py") for argument in arguments)
    except OSError:
        return True


def check_lock(lock_file):
    for _attempt in range(2):
        try:
            descriptor = os.open(lock_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="ascii") as file:
                file.write(str(os.getpid()))
            return True
        except FileExistsError:
            if lock_owner_running(lock_file):
                print("脚本已经在运行中。")
                return False
            try:
                os.remove(lock_file)
            except FileNotFoundError:
                pass
            except OSError as error:
                print("无法清理陈旧锁文件: ", error)
                return False
        except OSError as error:
            print("无法创建锁文件: ", error)
            return False
    return False

def remove_lock(lock_file):
    try:
        os.remove(lock_file)
    except FileNotFoundError:
        pass
    except Exception as e:
        print("无法删除锁文件: ", e)

def forward():
    lock_file = "/tmp/smstrun-AK68.lock"
    if not check_lock(lock_file):
        return
    
    try:
        token = read_token_from_config()
        print("Enjoy! 已完成测试并开启转发功能，重启后完成开机自启。")
        count = 0
        active_storage_identity = None
        state_initialized = False
        fingerprint_order = []
        seen_fingerprints = set()
        empty_baseline_confirmations = 0
        last_storage_used = None
        last_full_scan = 0.0
        while True:
            try:
                storage_identity = sms_pdu_AK68.read_sms_storage_identity()
                if storage_identity != active_storage_identity:
                    active_storage_identity = storage_identity
                    state_initialized, fingerprint_order = load_forward_state(
                        active_storage_identity
                    )
                    seen_fingerprints = set(fingerprint_order)
                    empty_baseline_confirmations = 0
                    last_storage_used = None
                    last_full_scan = 0.0
                    if state_initialized:
                        print("已切换到存在短信转发基线的 SIM 存储。")
                    else:
                        print("检测到新的 SIM 存储，将先建立历史短信基线。")

                usage = sms_pdu_AK68.read_storage_usage()
                now = time.monotonic()
                scanned = (
                    not state_initialized
                    or last_storage_used is None
                    or usage[0] != last_storage_used
                    or now - last_full_scan >= FULL_SMS_SCAN_INTERVAL
                )
                if scanned:
                    messages, errors = sms_pdu_AK68.read_messages_by_index("all", usage)
                    last_storage_used = usage[0]
                    last_full_scan = now
                else:
                    messages, errors = [], []

                if scanned:
                    confirmed_identity = sms_pdu_AK68.read_sms_storage_identity()
                    if confirmed_identity != active_storage_identity:
                        print("扫描期间 SIM 存储发生切换，本轮结果已丢弃。")
                        active_storage_identity = None
                        last_storage_used = None
                        save_forward_health(
                            False,
                            storage_used=usage[0],
                            scanned=True,
                            ready=False,
                            error="扫描期间 SIM 存储发生切换，正在重新建立基线。",
                        )
                        time.sleep(POLL_INTERVAL)
                        continue

                for error in errors:
                    print(error)

                # A baseline belongs to one physical SIM identity. A newly
                # selected SIM must never inherit another SIM's empty or stale
                # baseline. Empty storage is confirmed repeatedly because the
                # modem can temporarily report zero while reinitializing.
                if not state_initialized:
                    empty_baseline_confirmations, baseline_ready = baseline_confirmation(
                        usage[0],
                        errors,
                        empty_baseline_confirmations,
                    )
                    if establish_forward_baseline(
                        active_storage_identity,
                        messages,
                        fingerprint_order,
                        seen_fingerprints,
                        initialized=baseline_ready,
                    ):
                        state_initialized = baseline_ready
                        if state_initialized:
                            print(
                                "已建立短信转发基线，共记录 "
                                f"{len(fingerprint_order)} 个短信分段。"
                            )
                        else:
                            print(
                                "短信存储暂为空，正在确认基线 "
                                f"({empty_baseline_confirmations}/"
                                f"{EMPTY_BASELINE_CONFIRMATIONS})。"
                            )
                    else:
                        print("无法持久保存短信基线，本轮不会转发任何短信。")
                    save_forward_health(
                        not errors,
                        storage_used=usage[0],
                        scanned=scanned,
                        ready=state_initialized,
                        error="；".join(errors) if errors else None,
                    )
                    time.sleep(POLL_INTERVAL)
                    continue

                forwarded = False
                retry_delivery = False
                for sms in messages:
                    fingerprints = set(sms["fingerprints"])
                    if fingerprints.issubset(seen_fingerprints):
                        continue

                    if not sms["complete"]:
                        print(
                            "长短信尚未收全，等待剩余分段: "
                            f"{len(sms['indexes'])}/{sms['segment_count']}"
                        )
                        continue

                    timestamp_allowed, timestamp_error = forwarding_timestamp_allowed(
                        sms.get("timestamp")
                    )
                    if not timestamp_allowed:
                        print(f"跳过不符合 24 小时转发窗口的短信: {timestamp_error}。")
                        remember_fingerprints(
                            fingerprint_order,
                            seen_fingerprints,
                            sms["fingerprints"],
                        )
                        if not save_forward_state(
                            active_storage_identity,
                            fingerprint_order,
                        ):
                            print("无法保存已跳过短信的去重状态。")
                        continue

                    message = sms_pdu_AK68.format_message(sms)
                    if push_pushplus(message, token, read_title_from_config()):
                        remember_fingerprints(
                            fingerprint_order,
                            seen_fingerprints,
                            sms["fingerprints"],
                        )
                        save_forward_state(
                            active_storage_identity,
                            fingerprint_order,
                        )
                        count += 1
                        write_summary_to_file(count, message)
                        forwarded = True
                    else:
                        retry_delivery = True

                if errors or retry_delivery:
                    # Retry a failed decode or push on the next cycle even if
                    # the number of occupied SMS slots did not change.
                    last_storage_used = None

                save_forward_health(
                    not errors and not retry_delivery,
                    storage_used=usage[0],
                    scanned=scanned,
                    ready=True,
                    error=("；".join(errors) if errors else "短信推送失败") if (errors or retry_delivery) else None,
                )
                if not forwarded and scanned:
                    print("未检测到新消息，继续检测...")
            except Exception as e:
                print("发生未处理异常: ", str(e))
                save_forward_health(
                    False,
                    ready=state_initialized,
                    error=e,
                )
                last_storage_used = None
            time.sleep(POLL_INTERVAL)
    finally:
        remove_lock(lock_file)

def push_pushplus(message, token, title):
    url = "https://www.pushplus.plus/send"
    data = {
        "token": token,
        "title": title,
        "content": message
    }
    try:
        response = requests.post(url, json=data, timeout=15)
        response.raise_for_status()
        result = response.json()
        print("Response:\n", result)
        return str(result.get("code")) == "200"
    except Exception as e:
        print("Error occurred: ", str(e))
        return False

if __name__ == '__main__':
    forward()
