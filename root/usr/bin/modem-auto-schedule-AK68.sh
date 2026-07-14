#!/bin/sh

STATE_FILE="/tmp/modem-auto-schedule-AK68.state"
TAG="ModemATSD"
INTERVAL=30

log_message() {
	logger -t "$TAG" "[自动网络] $*"
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

is_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
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

restore_saved_lock() {
	local modem_type mode band band_nsa nrmode freqlock earfcn cellid scs result lock_command

	modem_type="$(get_modem_type)" || return 1
	mode="$(uci -q get modem-AK68.@ndis[0].smode)"
	freqlock="$(uci -q get modem-AK68.@ndis[0].freqlock)"
	earfcn="$(uci -q get modem-AK68.@ndis[0].earfcn)"
	cellid="$(uci -q get modem-AK68.@ndis[0].cellid)"

	case "$modem_type:$mode" in
		balong:0|quectel:0)
			return 0
			;;
		balong:1)
			band="$(uci -q get modem-AK68.@ndis[0].bandlist_lte)"
			band="${band:-0}"
			is_uint "$band" || return 1
			[ "$band" -gt 0 ] || return 0
			lock_command="AT^LTEFREQLOCK=3,0,1,\"$band\""
			if [ "$freqlock" = "1" ]; then
				is_uint "$earfcn" && is_uint "$cellid" && [ "$earfcn" -gt 0 ] && [ "$cellid" -gt 0 ] || return 1
				lock_command="AT^LTEFREQLOCK=2,0,1,\"$band\",\"$earfcn\",\"$cellid\""
			fi
			send_at 'AT+CFUN=0' || return 1
			sleep 2
			result=0
			send_at "$lock_command" || result=1
			send_at 'AT+CFUN=1' || result=1
			return "$result"
			;;
		balong:2)
			band="$(uci -q get modem-AK68.@ndis[0].bandlist_sa)"
			band="${band:-0}"
			is_uint "$band" || return 1
			[ "$band" -gt 0 ] || return 0
			lock_command="AT^NRFREQLOCK=3,0,1,\"$band\""
			if [ "$freqlock" = "1" ]; then
				is_uint "$earfcn" && is_uint "$cellid" && [ "$earfcn" -gt 0 ] && [ "$cellid" -gt 0 ] || return 1
				case "$band" in
					1|2|3|5|7|8|12|20|25|28|66|71|75|76) scs=0 ;;
					38|40|41|48|77|78|79) scs=1 ;;
					257|258|260|261) scs=3 ;;
					*) return 1 ;;
				esac
				lock_command="AT^NRFREQLOCK=2,0,1,\"$band\",\"$earfcn\",\"$scs\",\"$cellid\""
			fi
			send_at 'AT+CFUN=0' || return 1
			sleep 2
			result=0
			send_at "$lock_command" || result=1
			send_at 'AT+CFUN=1' || result=1
			return "$result"
			;;
		quectel:1)
			band="$(uci -q get modem-AK68.@ndis[0].bandlist_lte)"
			band="${band:-0}"
			is_uint "$band" || return 1
			[ "$band" -gt 0 ] || band='1:3:5:8:34:38:39:40:41'
			send_at "AT+QNWPREFCFG=\"lte_band\",$band" || return 1
			[ "$freqlock" = "1" ] || return 0
			is_uint "$earfcn" && is_uint "$cellid" && [ "$earfcn" -gt 0 ] && [ "$cellid" -gt 0 ] || return 1
			send_at "AT+QNWLOCK=\"common/4g\",1,$cellid,$earfcn" && send_at 'AT+QNWLOCK="save_ctrl",1,1'
			;;
		quectel:2)
			band="$(uci -q get modem-AK68.@ndis[0].bandlist_sa)"
			band_nsa="$(uci -q get modem-AK68.@ndis[0].bandlist_nsa)"
			nrmode="$(uci -q get modem-AK68.@ndis[0].nrmode)"
			band="${band:-0}"
			band_nsa="${band_nsa:-0}"
			nrmode="${nrmode:-0}"
			is_uint "$band" && is_uint "$band_nsa" && is_uint "$nrmode" || return 1
			[ "$band" -gt 0 ] || band='1:3:8:28:41:78:79'
			[ "$band_nsa" -gt 0 ] || band_nsa='41:78:79'
			send_at "AT+QNWPREFCFG=\"nr5g_band\",$band" || return 1
			send_at "AT+QNWPREFCFG=\"nsa_nr5g_band\",$band_nsa" || return 1
			case "$nrmode" in
				0) send_at 'AT+QNWPREFCFG="nr5g_disable_mode",0' || return 1 ;;
				1) send_at 'AT+QNWPREFCFG="nr5g_disable_mode",2' || return 1 ;;
				2) send_at 'AT+QNWPREFCFG="nr5g_disable_mode",1' || return 1 ;;
				*) return 1 ;;
			esac
			[ "$freqlock" = "1" ] || return 0
			is_uint "$earfcn" && is_uint "$cellid" && [ "$earfcn" -gt 0 ] && [ "$cellid" -gt 0 ] || return 1
			case "$band" in *:*) return 1 ;; esac
			case "$band" in
				1|2|3|5|7|8|12|20|25|28|66|71|75|76) scs=0 ;;
				38|40|41|48|77|78|79) scs=1 ;;
				257|258|260|261) scs=3 ;;
				*) return 1 ;;
			esac
			send_at "AT+QNWLOCK=\"common/5g\",$cellid,$earfcn,$scs,$band" &&
				send_at 'AT+QNWLOCK="save_ctrl",1,1'
			;;
		*)
			log_message "当前保存的网络模式没有可恢复的锁频/锁小区配置"
			return 1
			;;
	esac
}

enter_auto_mode() {
	apply_network_mode 0 && clear_network_locks
}

restore_saved_settings() {
	local mode
	mode="$(uci -q get modem-AK68.@ndis[0].smode)"
	mode="${mode:-0}"
	apply_network_mode "$mode" && restore_saved_lock
}

check_schedule() {
	local enabled start end start_minutes end_minutes now_minutes state configured_mode in_window expected_state
	enabled="$(uci -q get modem-AK68.@ndis[0].auto_schedule_enable)"
	state="$(cat "$STATE_FILE" 2>/dev/null)"

	if [ "$enabled" != "1" ]; then
		case "$state" in
		auto:*)
			restore_saved_settings || return
			log_message "定时功能已关闭，已恢复保存的网络与锁定设置"
			;;
		esac
		rm -f "$STATE_FILE"
		return
	fi

	start="$(uci -q get modem-AK68.@ndis[0].auto_schedule_start)"
	end="$(uci -q get modem-AK68.@ndis[0].auto_schedule_end)"
	start_minutes="$(time_to_minutes "${start:-02:00}")" || return
	end_minutes="$(time_to_minutes "${end:-06:00}")" || return
	now_minutes="$(time_to_minutes "$(date +%H:%M)")" || return
	in_window=0

	if [ "$start_minutes" -lt "$end_minutes" ]; then
		[ "$now_minutes" -ge "$start_minutes" ] && [ "$now_minutes" -lt "$end_minutes" ] && in_window=1
	elif [ "$start_minutes" -gt "$end_minutes" ]; then
		{ [ "$now_minutes" -ge "$start_minutes" ] || [ "$now_minutes" -lt "$end_minutes" ]; } && in_window=1
	else
		# 开始与结束相同时视为全天自动模式。
		in_window=1
	fi

	if [ "$in_window" -eq 1 ]; then
		configured_mode="$(uci -q get modem-AK68.@ndis[0].smode)"
		configured_mode="${configured_mode:-0}"
		expected_state="auto:$configured_mode:$start:$end"
		if [ "$state" != "$expected_state" ]; then
			enter_auto_mode && {
				echo "$expected_state" > "$STATE_FILE"
				log_message "已进入自动网络时间段并解除锁频/锁小区 ($start-$end)"
			}
		fi
	elif echo "$state" | grep -q '^auto:'; then
		configured_mode="$(uci -q get modem-AK68.@ndis[0].smode)"
		configured_mode="${configured_mode:-0}"
		restore_saved_settings && {
			echo "configured" > "$STATE_FILE"
			log_message "自动网络时间段结束，已恢复模式 $configured_mode 及锁定设置"
		}
	elif [ -z "$state" ]; then
		echo "configured" > "$STATE_FILE"
	fi
}

if [ "$1" = "--once" ]; then
	check_schedule
	exit $?
fi

while true; do
	check_schedule
	sleep "$INTERVAL"
done
