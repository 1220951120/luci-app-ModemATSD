#!/bin/sh

STATE_FILE="/tmp/modem-auto-schedule-AK68.state"
LOCK_FILE="/tmp/modem-auto-schedule-AK68.lock"
TAG="ModemATSD"
INTERVAL=5

log_message() {
	logger -t "$TAG" "[分时锁网] $*"
}

time_to_minutes() {
	local value="$1"
	local hour="${value%:*}"
	local minute="${value#*:}"

	case "$value" in
		[0-2][0-9]:[0-5][0-9]) ;;
		*) return 1 ;;
	esac

	hour="${hour#0}"
	minute="${minute#0}"
	[ -n "$hour" ] || hour=0
	[ -n "$minute" ] || minute=0
	[ "$hour" -le 23 ] || return 1
	echo $((hour * 60 + minute))
}

validate_rules() {
	local rules="$1"
	awk -v rules="$rules" '
	function fail(message) {
		print message
		exit 1
	}
	function valid_time(value, parts, hour, minute) {
		if (value !~ /^[0-9][0-9]:[0-9][0-9]$/)
			return -1
		split(value, parts, ":")
		hour = parts[1] + 0
		minute = parts[2] + 0
		if (hour > 23 || minute > 59)
			return -1
		return hour * 60 + minute
	}
	function valid_lte_band(value) {
		return value ~ /^(1|3|5|8|34|38|39|40|41)$/
	}
	function valid_sa_band(value) {
		return value ~ /^(1|3|5|8|28|41|78|79)$/
	}
	BEGIN {
		if (length(rules) > 2048)
			fail("规则数据过长")
		if (rules == "") {
			print "OK"
			exit 0
		}

		count = split(rules, records, ";")
		if (count > 8)
			fail("最多只能配置 8 条分时锁网规则")

		for (i = 1; i <= count; i++) {
			if (records[i] == "")
				fail("规则 " i " 为空")
			field_count = split(records[i], fields, ",")
			if (field_count != 8)
				fail("规则 " i " 格式错误")

			enabled = fields[1]
			start = valid_time(fields[2])
			finish = valid_time(fields[3])
			type = fields[4]
			mobility = fields[5]
			band = fields[6]
			earfcn = fields[7]
			pci = fields[8]

			if (enabled != "0" && enabled != "1")
				fail("规则 " i " 的启用状态无效")
			if (start < 0 || finish < 0)
				fail("规则 " i " 的时间必须为 HH:MM")
			if (start == finish && fields[2] != "00:00")
				fail("规则 " i " 只有 00:00 到 00:00 可表示全天")
			if (mobility != "0" && mobility != "1")
				fail("规则 " i " 的重选与切换设置无效")
			if (band !~ /^[0-9]+$/ || earfcn !~ /^[0-9]+$/ || pci !~ /^[0-9]+$/)
				fail("规则 " i " 的频段、EARFCN 和 PCI 必须为数字")

			if (type == "lte_band" || type == "lte_cell") {
				if (!valid_lte_band(band))
					fail("规则 " i " 的 LTE 频段不受支持")
			}
			else if (type == "nr_sa_band" || type == "nr_sa_cell") {
				if (!valid_sa_band(band))
					fail("规则 " i " 的 5G-SA 频段不受支持")
			}
			else {
				fail("规则 " i " 的锁网类型无效")
			}

			if (type ~ /_band$/) {
				if (earfcn != "0" || pci != "0")
					fail("规则 " i " 仅锁频段时 EARFCN 和 PCI 必须为 0")
			}
			else {
				if ((earfcn + 0) <= 0)
					fail("规则 " i " 的 EARFCN 必须大于 0")
				if (type == "lte_cell" && (pci + 0) > 503)
					fail("规则 " i " 的 LTE PCI 必须在 0-503 之间")
				if (type == "nr_sa_cell" && (pci + 0) > 1007)
					fail("规则 " i " 的 5G PCI 必须在 0-1007 之间")
			}

			if (enabled == "1") {
				minute = start
				minutes_to_claim = start == finish ? 1440 : (finish - start + 1440) % 1440
				for (claimed = 0; claimed < minutes_to_claim; claimed++) {
					if (owner[minute] != "")
						fail("规则 " i " 与规则 " owner[minute] " 的时间段重叠")
					owner[minute] = i
					minute = (minute + 1) % 1440
				}
			}
		}
		print "OK"
	}
	'
}

select_active_rule() {
	local rules="$1"
	local now_minutes="$2"
	local remaining record enabled start end type mobility band earfcn pci
	local start_minutes end_minutes index old_ifs

	remaining="$rules"
	index=0
	while [ -n "$remaining" ]; do
		case "$remaining" in
			*';'*) record="${remaining%%;*}"; remaining="${remaining#*;}" ;;
			*) record="$remaining"; remaining="" ;;
		esac
		index=$((index + 1))

		old_ifs="$IFS"
		IFS=,
		set -- $record
		IFS="$old_ifs"
		[ "$#" -eq 8 ] || continue
		enabled="$1"
		start="$2"
		end="$3"
		type="$4"
		mobility="$5"
		band="$6"
		earfcn="$7"
		pci="$8"
		[ "$enabled" = "1" ] || continue

		start_minutes="$(time_to_minutes "$start")" || continue
		end_minutes="$(time_to_minutes "$end")" || continue
		if [ "$start_minutes" -lt "$end_minutes" ]; then
			[ "$now_minutes" -ge "$start_minutes" ] && [ "$now_minutes" -lt "$end_minutes" ] || continue
		else
			{ [ "$now_minutes" -ge "$start_minutes" ] || [ "$now_minutes" -lt "$end_minutes" ]; } || continue
		fi

		echo "$index,$enabled,$start,$end,$type,$mobility,$band,$earfcn,$pci"
		return 0
	done
	return 1
}

get_modem_type() {
	local modem_type
	modem_type="$(cat /tmp/modconf-AK68.conf 2>/dev/null)"
	case "$modem_type" in
		*RM520*|*RM500*) echo "quectel" ;;
		*MT5700*|*NU313*) echo "balong" ;;
		*) return 1 ;;
	esac
}

send_at() {
	local command="$1"
	local output
	log_message "执行 AT 命令: $command"
	output="$(atsd_tools_cli -i cpe -c "$command" 2>&1)"
	echo "$output" | grep -q "OK" || {
		log_message "AT命令执行失败: $command; $output"
		return 1
	}
	log_message "AT 命令执行成功: $command"
}

apply_network_mode() {
	local mode="$1"
	local modem_type
	modem_type="$(get_modem_type)" || {
		log_message "尚未识别到支持的模组，稍后重试"
		return 1
	}

	case "$modem_type:$mode" in
		quectel:0) send_at 'AT+QNWPREFCFG="mode_pref",AUTO' ;;
		quectel:1) send_at 'AT+QNWPREFCFG="mode_pref",LTE' ;;
		quectel:2) send_at 'AT+QNWPREFCFG="mode_pref",NR5G' ;;
		balong:0) send_at 'AT^SYSCFGEX="080302",2000000680380,1,2,1E200000095,,' ;;
		balong:1) send_at 'AT^SYSCFGEX="03",2000000680380,1,2,1E200000095,,' ;;
		balong:2)
			send_at 'AT^SYSCFGEX="08",2000000680380,1,2,1E200000095,,' &&
			send_at 'AT^C5GOPTION=1,1,1'
			;;
		*)
			log_message "不支持的网络模式: $mode"
			return 1
			;;
	esac
}

clear_network_locks() {
	local modem_type result
	modem_type="$(get_modem_type)" || return 1
	result=0

	case "$modem_type" in
		balong)
			send_at 'AT^LTEFREQLOCK=0' || result=1
			send_at 'AT^NRFREQLOCK=0' || result=1
			;;
		quectel)
			send_at 'AT+QNWLOCK="common/5g",0' || result=1
			send_at 'AT+QNWLOCK="common/4g",0' || result=1
			send_at 'AT+QNWPREFCFG="lte_band",1:3:5:8:34:38:39:40:41' || result=1
			send_at 'AT+QNWPREFCFG="nr5g_band",1:3:8:28:41:78:79' || result=1
			send_at 'AT+QNWPREFCFG="nsa_nr5g_band",41:78:79' || result=1
			send_at 'AT+QNWPREFCFG="nr5g_disable_mode",0' || result=1
			;;
	esac

	return "$result"
}

scs_for_band() {
	case "$1" in
		1|2|3|5|7|8|12|20|25|28|66|71|75|76) echo 0 ;;
		38|40|41|48|77|78|79) echo 1 ;;
		257|258|260|261) echo 3 ;;
		*) return 1 ;;
	esac
}

apply_scheduled_rule() {
	local active_rule="$1"
	local index enabled start end type mobility band earfcn pci modem_type mode scs
	local lock_command result old_ifs

	old_ifs="$IFS"
	IFS=,
	set -- $active_rule
	IFS="$old_ifs"
	[ "$#" -eq 9 ] || return 1
	index="$1"
	enabled="$2"
	start="$3"
	end="$4"
	type="$5"
	mobility="$6"
	band="$7"
	earfcn="$8"
	pci="$9"
	[ "$enabled" = "1" ] || return 1

	modem_type="$(get_modem_type)" || {
		log_message "尚未识别到支持的模组，稍后重试"
		return 1
	}
	clear_network_locks || return 1

	case "$type" in
		lte_band|lte_cell) mode=1 ;;
		nr_sa_band|nr_sa_cell) mode=2 ;;
		*) return 1 ;;
	esac
	apply_network_mode "$mode" || return 1

	case "$modem_type:$type" in
		balong:lte_band)
			lock_command="AT^LTEFREQLOCK=3,$mobility,1,\"$band\""
			;;
		balong:lte_cell)
			lock_command="AT^LTEFREQLOCK=2,$mobility,1,\"$band\",\"$earfcn\",\"$pci\""
			;;
		balong:nr_sa_band)
			lock_command="AT^NRFREQLOCK=3,$mobility,1,\"$band\""
			;;
		balong:nr_sa_cell)
			scs="$(scs_for_band "$band")" || return 1
			lock_command="AT^NRFREQLOCK=2,$mobility,1,\"$band\",\"$earfcn\",\"$scs\",\"$pci\""
			;;
		quectel:lte_band|quectel:lte_cell)
			send_at "AT+QNWPREFCFG=\"lte_band\",$band" || return 1
			if [ "$type" = "lte_cell" ]; then
				send_at "AT+QNWLOCK=\"common/4g\",1,$pci,$earfcn" || return 1
				send_at 'AT+QNWLOCK="save_ctrl",1,1' || return 1
				log_message "已应用规则 $index ($start-$end, LTE B$band, EARFCN $earfcn, PCI $pci)"
			else
				log_message "已应用规则 $index ($start-$end, LTE B$band)"
			fi
			return 0
			;;
		quectel:nr_sa_band|quectel:nr_sa_cell)
			send_at "AT+QNWPREFCFG=\"nr5g_band\",$band" || return 1
			send_at 'AT+QNWPREFCFG="nr5g_disable_mode",2' || return 1
			if [ "$type" = "nr_sa_cell" ]; then
				scs="$(scs_for_band "$band")" || return 1
				send_at "AT+QNWLOCK=\"common/5g\",$pci,$earfcn,$scs,$band" || return 1
				send_at 'AT+QNWLOCK="save_ctrl",1,1' || return 1
				log_message "已应用规则 $index ($start-$end, 5G-SA N$band, EARFCN $earfcn, PCI $pci)"
			else
				log_message "已应用规则 $index ($start-$end, 5G-SA N$band)"
			fi
			return 0
			;;
		*)
			return 1
			;;
	esac

	send_at 'AT+CFUN=0' || return 1
	sleep 2
	result=0
	send_at "$lock_command" || result=1
	send_at 'AT+CFUN=1' || result=1
	[ "$result" -eq 0 ] || return 1
	log_message "已应用规则 $index ($start-$end, $type, Band $band, EARFCN $earfcn, PCI $pci)"
}

enter_auto_mode() {
	clear_network_locks && apply_network_mode 0
}

check_schedule() {
	local enabled rules validation now_minutes state active_rule expected_state
	enabled="$(uci -q get modem-AK68.@ndis[0].lock_schedule_enable)"
	state="$(cat "$STATE_FILE" 2>/dev/null)"

	# A full modem apply can run after saving the CBI form. Do not interleave
	# multi-command lock transitions with that initialization sequence. The
	# apply may overwrite the scheduled lock, so force a fresh transition once
	# it finishes instead of trusting the previous runtime state.
	if ps w | grep -E '[M]T5700-AK68.sh|[r]m520n-AK68.sh|[5]00U-AK68.sh' >/dev/null 2>&1; then
		rm -f "$STATE_FILE"
		return
	fi

	if [ "$enabled" != "1" ]; then
		expected_state="schedule-disabled-auto"
		if [ "$state" != "$expected_state" ]; then
			enter_auto_mode || return
			echo "$expected_state" > "$STATE_FILE"
			log_message "分时锁网已关闭，已恢复自动网络并解除锁定"
		fi
		return
	fi

	rules="$(uci -q get modem-AK68.@ndis[0].lock_schedule_rules)"
	validation="$(validate_rules "$rules")" || {
		if [ "$state" != "schedule-auto-invalid" ]; then
			enter_auto_mode || return
			echo "schedule-auto-invalid" > "$STATE_FILE"
			log_message "规则无效，已进入自动网络：$validation"
		fi
		return
	}

	now_minutes="$(time_to_minutes "$(date +%H:%M)")" || return
	active_rule="$(select_active_rule "$rules" "$now_minutes")"

	if [ -n "$active_rule" ]; then
		expected_state="rule:$active_rule"
		if [ "$state" != "$expected_state" ]; then
			apply_scheduled_rule "$active_rule" && {
				echo "$expected_state" > "$STATE_FILE"
			}
		fi
	else
		expected_state="schedule-auto"
		if [ "$state" != "$expected_state" ]; then
			enter_auto_mode && {
				echo "$expected_state" > "$STATE_FILE"
				log_message "当前时间未命中锁网规则，已恢复自动网络并解除锁定"
			}
		fi
	fi
}

case "$1" in
	--validate)
		validate_rules "$2"
		exit $?
		;;
	--select)
		validate_rules "$2" >/dev/null || exit 1
		now_minutes="$(time_to_minutes "$3")" || exit 1
		active_rule="$(select_active_rule "$2" "$now_minutes")"
		if [ -n "$active_rule" ]; then
			echo "rule:$active_rule"
		else
			echo "auto"
		fi
		exit 0
		;;
esac

exec 201>"$LOCK_FILE"
flock -n 201 || exit 0

if [ "$1" = "--once" ]; then
	check_schedule
	exit $?
fi

while true; do
	check_schedule
	sleep "$INTERVAL"
done
