#!/bin/sh

. "${IPKG_INSTROOT:-}/usr/bin/modem-led-control-AK68.sh"

STATE=/tmp/modem-led-schedule-AK68.state
ENABLE_STATE=/tmp/modem-led-schedule-AK68.enabled
TAG=ModemATSD

log_message() {
    logger -t "$TAG" "[LED定时] $*"
}

set_leds() {
    modem_led_set "$1" cmode4 cmode5 wifi status sig1 sig2 sig3 int
}

lights_off() {
    set_leds 0
    echo 0 > /tmp/ledflag.conf
    echo 0 > /usr/bin/ledflagc.conf
}

lights_auto() {
    rm -f /tmp/ledflag.conf /usr/bin/ledflagc.conf
    modem_led_set 1 wifi status
}

time_to_minutes() {
    value="$1"
    hour="${value%:*}"
    minute="${value#*:}"
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

check_schedule() {
    enabled="$(uci -q get modem-AK68.@ndis[0].led_schedule_enable)"
    off_time="$(uci -q get modem-AK68.@ndis[0].led_schedule_off)"
    on_time="$(uci -q get modem-AK68.@ndis[0].led_schedule_on)"
    previous_enabled="$(cat "$ENABLE_STATE" 2>/dev/null)"
    last="$(cat "$STATE" 2>/dev/null)"

    if [ "$enabled" != "1" ]; then
        if [ "$previous_enabled" != "0" ]; then
            log_message "LED 定时控制已停用"
        fi
        case "$last" in
            off|*-off)
                lights_auto
                log_message "LED 定时控制停用，已恢复自动灯光控制"
                ;;
        esac
        echo 0 > "$ENABLE_STATE"
        rm -f "$STATE"
        return 0
    fi

    off_time="${off_time:-23:00}"
    on_time="${on_time:-07:00}"
    off_minutes="$(time_to_minutes "$off_time")" || {
        [ "$last" = "invalid" ] || log_message "LED 定时关闭时间无效: $off_time"
        echo invalid > "$STATE"
        return 1
    }
    on_minutes="$(time_to_minutes "$on_time")" || {
        [ "$last" = "invalid" ] || log_message "LED 定时开启时间无效: $on_time"
        echo invalid > "$STATE"
        return 1
    }
    now_minutes="$(time_to_minutes "$(date +%H:%M)")" || return 1

    if [ "$previous_enabled" != "1" ]; then
        log_message "LED 定时控制已启用，关闭时段: $off_time-$on_time"
    fi
    echo 1 > "$ENABLE_STATE"

    target=on
    if [ "$off_minutes" -lt "$on_minutes" ]; then
        [ "$now_minutes" -ge "$off_minutes" ] && [ "$now_minutes" -lt "$on_minutes" ] && target=off
    elif [ "$off_minutes" -gt "$on_minutes" ]; then
        { [ "$now_minutes" -ge "$off_minutes" ] || [ "$now_minutes" -lt "$on_minutes" ]; } && target=off
    else
        target=off
    fi

    case "$last" in *-off) last=off ;; *-on) last=on ;; esac
    if [ "$target" = "off" ] && [ "$last" != "off" ]; then
        lights_off
        echo off > "$STATE"
        log_message "已进入 LED 关闭时段 ($off_time-$on_time)，永久关闭所有灯光"
    elif [ "$target" = "on" ] && [ "$last" != "on" ]; then
        lights_auto
        echo on > "$STATE"
        log_message "已离开 LED 关闭时段 ($off_time-$on_time)，恢复自动灯光控制"
    fi
}

case "$1" in
    check) check_schedule;;
    run) while true; do check_schedule; sleep 20; done;;
    off) lights_off; log_message "手动永久关闭所有灯光";;
    on) lights_auto; log_message "手动恢复自动灯光控制";;
    *) echo "Usage: $0 {run|check|off|on}" >&2; exit 1;;
esac
