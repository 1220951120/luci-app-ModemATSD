import json
import os
import time
import requests
from datetime import datetime

import sms_pdu_AK68


FORWARD_STATE_PATH = "/etc/modem-sms-forward-AK68.state"
FORWARD_STATE_VERSION = 1
MAX_SAVED_FINGERPRINTS = 4096


def load_forward_state(path=FORWARD_STATE_PATH):
    try:
        with open(path, "r", encoding="utf-8") as file:
            data = json.load(file)
        if data.get("version") != FORWARD_STATE_VERSION:
            raise ValueError("状态版本不受支持")

        fingerprints = []
        seen = set()
        for value in data.get("fingerprints", []):
            if not isinstance(value, str) or len(value) != 64:
                continue
            if value in seen:
                continue
            seen.add(value)
            fingerprints.append(value)
        return True, fingerprints[-MAX_SAVED_FINGERPRINTS:]
    except FileNotFoundError:
        return False, []
    except Exception as error:
        print(f"读取短信转发去重状态失败，将重新建立基线: {error}")
        return False, []


def save_forward_state(fingerprints, path=FORWARD_STATE_PATH):
    temporary_path = f"{path}.tmp.{os.getpid()}"
    data = {
        "version": FORWARD_STATE_VERSION,
        "fingerprints": list(fingerprints)[-MAX_SAVED_FINGERPRINTS:],
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


def establish_forward_baseline(messages, fingerprint_order, seen_fingerprints, path=FORWARD_STATE_PATH):
    for sms in messages:
        remember_fingerprints(
            fingerprint_order,
            seen_fingerprints,
            sms["fingerprints"],
        )
    return save_forward_state(fingerprint_order, path)


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

def check_lock(lock_file):
    if os.path.exists(lock_file):
        print("脚本已经在运行中。")
        return False
    else:
        try:
            with open(lock_file, 'w') as file:
                file.write(str(os.getpid()))
            return True
        except Exception as e:
            print("无法创建锁文件: ", e)
            return False

def remove_lock(lock_file):
    try:
        os.remove(lock_file)
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
        state_initialized, fingerprint_order = load_forward_state()
        seen_fingerprints = set(fingerprint_order)
        while True:
            try:
                messages, errors = sms_pdu_AK68.read_messages("all")
                for error in errors:
                    print(error)

                # The first run only records what is already stored on the
                # modem. This prevents package upgrades, service restarts, or
                # a replaced/corrupt state file from forwarding the inbox as
                # if every historical unread SMS had just arrived.
                if not state_initialized:
                    if establish_forward_baseline(
                        messages,
                        fingerprint_order,
                        seen_fingerprints,
                    ):
                        state_initialized = True
                        print(f"已建立短信转发基线，共记录 {len(fingerprint_order)} 个短信分段。")
                    else:
                        print("无法持久保存短信基线，本轮不会转发任何短信。")
                    time.sleep(5)
                    continue

                forwarded = False
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

                    message = sms_pdu_AK68.format_message(sms)
                    if push_pushplus(message, token, read_title_from_config()):
                        remember_fingerprints(
                            fingerprint_order,
                            seen_fingerprints,
                            sms["fingerprints"],
                        )
                        save_forward_state(fingerprint_order)
                        count += 1
                        write_summary_to_file(count, message)
                        forwarded = True

                if not forwarded:
                    print("未检测到新消息，继续检测...")
            except Exception as e:
                print("发生未处理异常: ", str(e))
            time.sleep(5)
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
