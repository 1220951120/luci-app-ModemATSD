#!/bin/sh

LOCK_FILE="${MODEM_SIM_LOCK_FILE:-/var/lock/modem-sim-switch-AK68.lock}"
STATE_FILE="${MODEM_SIM_STATE_FILE:-/tmp/sim_sel_AK68}"
INIT_LOG="${MODEM_SIM_INIT_LOG:-/tmp/moduleInit-AK68}"
AT_CLIENT="${MODEM_SIM_AT_CLIENT:-atsd_tools_cli}"

fail() {
	logger -t ModemATSD "[SIM切换] 失败：$*" 2>/dev/null
	printf 'ERROR: %s\n' "$*"
	exit 1
}

send_at() {
	command="$1"
	reply="$(timeout 10 "$AT_CLIENT" -i cpe -c "$command" 2>&1 | tr -d '\r')" || return 1
	printf '%s\n' "$reply" | grep -qx 'OK'
}

send_at_retry() {
	command="$1"
	attempt=0
	while [ "$attempt" -lt 3 ]; do
		send_at "$command" && return 0
		attempt=$((attempt+1))
		sleep 1
	done
	return 1
}

query_slot() {
	reply="$(timeout 10 "$AT_CLIENT" -i cpe -c 'AT^SCICHG?' 2>/dev/null | tr -d '\r')" || return 1
	printf '%s\n' "$reply" | sed -n 's/^[[:space:]]*\^SCICHG:[[:space:]]*\([01],[01]\)[[:space:]]*$/\1/p' | head -n1
}

record_slot() {
	printf '%s\n' "$slot" > "$STATE_FILE"
	printf '%s\n' "$label" >> "$INIT_LOG"
	logger -t ModemATSD "[SIM切换] 已切换到${label}" 2>/dev/null
}

slot="${1:-}"
case "$slot" in
	0)
		target='0,1'
		label='外置SIM卡'
		;;
	1)
		target='1,0'
		label='内置SIM卡1'
		;;
	*) fail '卡槽参数必须是 0（外置）或 1（内置）。' ;;
esac

mkdir -p "${LOCK_FILE%/*}" 2>/dev/null
exec 9>"$LOCK_FILE" || fail '无法创建切卡锁。'
flock -x 9 || fail '无法获取切卡锁。'

current="$(query_slot 2>/dev/null)"
if [ "$current" = "$target" ]; then
	record_slot
	echo OK
	exit 0
fi

send_at_retry "AT^SCICHG=$target" || fail '模组未接受卡槽切换命令。'
if send_at_retry 'AT^HVSST=1,0'; then
	sleep 3
	send_at_retry 'AT^HVSST=1,1' ||
		logger -t ModemATSD '[SIM切换] 卡槽已切换，但模组未确认重新开启蜂窝射频。' 2>/dev/null
else
	logger -t ModemATSD '[SIM切换] 卡槽已切换，但模组未确认蜂窝射频重启命令。' 2>/dev/null
fi

attempt=0
while [ "$attempt" -lt 10 ]; do
	current="$(query_slot 2>/dev/null)"
	if [ "$current" = "$target" ]; then
		record_slot
		echo OK
		exit 0
	fi
	attempt=$((attempt+1))
	sleep 1
done

fail "切卡后校验失败，模组当前返回：${current:-无数据}。"
