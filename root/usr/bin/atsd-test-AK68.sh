#!/bin/sh

PASS=0
WARN=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$*"; }
warn() { WARN=$((WARN + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$*"; }

test_at() {
    name="$1"
    command="$2"
    marker="$3"
    output="$(atsd_tools_cli -i cpe -c "$command" 2>&1 | tr -d '\r')"
    if echo "$output" | grep -q "$marker"; then
        pass "$name"
    else
        fail "$name - ${output:-no response}"
    fi
}

echo 'ATSD 功能自检（只执行查询，不修改模组设置）'
[ -x /usr/bin/atsd_tools_cli.real ] && pass '全局 AT 锁包装器与真实客户端存在' || fail 'AT 客户端文件不完整'
test_at 'AT 通道' 'AT' '^OK$'
test_at '模组型号' 'ATI' 'OK'
test_at 'SIM 卡状态' 'AT+CPIN?' 'CPIN:'
test_at '信号查询' 'AT^HCSQ?' 'HCSQ:'
test_at '网络驻留信息' 'AT^MONSC' 'MONSC'
test_at '载波聚合能力' 'AT^NRRCCAPQRY=3' 'NRRCCAPQRY:'
test_at '模组流量统计' 'AT^DSFLOWQRY' 'DSFLOWQRY:'

pgrep -f '^/bin/sh /usr/bin/modem-traffic-AK68.sh run$' >/dev/null && pass '流量统计后台服务' || warn '流量统计后台服务未运行'
pgrep -f '^/bin/sh /usr/bin/modem-led-schedule-AK68.sh run$' >/dev/null && pass 'LED 定时后台服务' || warn 'LED 定时后台服务未运行'
if [ -s /usr/bin/smstrun-AK68.conf ]; then
    /etc/init.d/modem-sms-forward-AK68 running >/dev/null 2>&1 && pass '短信转发后台服务' || warn '短信转发已配置但服务未运行'
    health_ok="$(python3 -c 'import json,time; data=json.load(open("/tmp/modem-sms-forward-AK68.health")); print(1 if data.get("ok") and time.time()-data.get("timestamp", 0) <= 120 else 0)' 2>/dev/null)"
    [ "$health_ok" = 1 ] && pass '短信转发读取链路' || warn '短信转发进程存在，但最近 120 秒内没有成功读取模组短信存储'
else
    pass '短信转发未配置，不启动后台服务'
fi
[ -s /etc/config/modem-AK68 ] && pass 'ATSD UCI 配置' || fail 'ATSD UCI 配置不存在'
[ -s /tmp/modem-traffic-AK68.state ] && pass '月度流量状态' || warn '月度流量状态尚未生成'

printf '\n结果：PASS=%s WARN=%s FAIL=%s\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
