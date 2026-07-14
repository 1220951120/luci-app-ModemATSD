#!/bin/sh

RUNTIME_STATE=/tmp/modem-traffic-AK68.state
PERSIST_STATE=/etc/modem-traffic-AK68.state
LOCK_DIR=/tmp/modem-traffic-AK68.lock
LAST_SAVE=/tmp/modem-traffic-AK68.lastsave

log_message() {
    logger -t ModemATSD "[流量] $*"
}

get_config() {
    ENABLED="$(uci -q get modem-AK68.@ndis[0].traffic_limit_enable)"
    LIMIT="$(uci -q get modem-AK68.@ndis[0].traffic_limit_bytes)"
    BILLING_DAY="$(uci -q get modem-AK68.@ndis[0].traffic_billing_day)"
    [ "$ENABLED" = "1" ] || ENABLED=0
    case "$LIMIT" in *[!0-9]*|'') LIMIT=107374182400;; esac
    case "$BILLING_DAY" in *[!0-9]*|'') BILLING_DAY=1;; esac
    [ "$BILLING_DAY" -ge 1 ] && [ "$BILLING_DAY" -le 28 ] || BILLING_DAY=1
}

period_key() {
    year="$(date +%Y)"
    month="$(date +%m)"
    day="$(date +%d)"
    month="${month#0}"
    day="${day#0}"
    key=$((year * 12 + month))
    [ "$day" -lt "$BILLING_DAY" ] && key=$((key - 1))
    echo "$key"
}

read_raw_total() {
    response="$(atsd_tools_cli -i cpe -c 'AT^DSFLOWQRY' 2>/dev/null | tr -d '\r')"
    values="$(echo "$response" | sed -n 's/^\^DSFLOWQRY:[[:space:]]*//p' | head -n1)"
    [ -n "$values" ] || return 1
    tx="$(echo "$values" | cut -d, -f5)"
    rx="$(echo "$values" | cut -d, -f6)"
    case "$tx$rx" in *[!0-9A-Fa-f]*) return 1;; esac
    RAW_TOTAL=$((0x$tx + 0x$rx))
    return 0
}

load_state() {
    PERIOD=0
    RAW=0
    USED=0
    BLOCKED=0
    state_file="$RUNTIME_STATE"
    [ -s "$state_file" ] || state_file="$PERSIST_STATE"
    if [ -s "$state_file" ]; then
        . "$state_file"
    fi
    for value in "$PERIOD" "$RAW" "$USED" "$BLOCKED"; do
        case "$value" in *[!0-9]*|'') PERIOD=0; RAW=0; USED=0; BLOCKED=0; break;; esac
    done
}

write_state() {
    target="$1"
    tmp="${target}.tmp.$$"
    umask 077
    printf 'PERIOD=%s\nRAW=%s\nUSED=%s\nBLOCKED=%s\n' "$PERIOD" "$RAW" "$USED" "$BLOCKED" > "$tmp"
    mv "$tmp" "$target"
}

save_state() {
    write_state "$RUNTIME_STATE"
    now="$(date +%s)"
    last="$(cat "$LAST_SAVE" 2>/dev/null)"
    case "$last" in *[!0-9]*|'') last=0;; esac
    if [ $((now - last)) -ge 900 ] || [ "$1" = "force" ]; then
        write_state "$PERSIST_STATE"
        echo "$now" > "$LAST_SAVE"
    fi
}

restore_network_if_blocked() {
    if [ "$BLOCKED" = "1" ]; then
        atsd_tools_cli -i cpe -c 'AT+CFUN=1' >/dev/null 2>&1
        BLOCKED=0
        log_message "流量限制已解除，蜂窝网络已恢复"
    fi
}

run_check() {
    get_config
    load_state
    current_period="$(period_key)"

    if [ "$BLOCKED" = "1" ] && { [ "$ENABLED" != "1" ] || { [ "$PERIOD" != "0" ] && [ "$PERIOD" != "$current_period" ]; }; }; then
        restore_network_if_blocked
        save_state force
        sleep 2
    fi
    read_raw_total || return 1

    if [ "$PERIOD" != "$current_period" ]; then
        restore_network_if_blocked
        PERIOD="$current_period"
        USED=0
        RAW="$RAW_TOTAL"
        save_state force
        log_message "进入新结算周期，已用流量重新从 0 开始统计"
    else
        if [ "$RAW_TOTAL" -ge "$RAW" ]; then
            USED=$((USED + RAW_TOTAL - RAW))
        fi
        RAW="$RAW_TOTAL"
    fi

    if [ "$ENABLED" = "1" ] && [ "$LIMIT" -gt 0 ] && [ "$USED" -ge "$LIMIT" ]; then
        if [ "$BLOCKED" != "1" ]; then
            atsd_tools_cli -i cpe -c 'AT+CFUN=0' >/dev/null 2>&1
            BLOCKED=1
            log_message "已达到每月流量上限，蜂窝网络已断开"
            save_state force
        fi
    else
        restore_network_if_blocked
    fi
    save_state
}

calibrate() {
    bytes="$1"
    case "$bytes" in *[!0-9]*|'') return 1;; esac
    get_config
    load_state
    read_raw_total || return 1
    PERIOD="$(period_key)"
    RAW="$RAW_TOTAL"
    USED="$bytes"
    save_state force
    run_check
}

acquire_lock() {
    mkdir "$LOCK_DIR" 2>/dev/null
}

release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null
}

case "$1" in
    check)
        acquire_lock || exit 0
        trap release_lock EXIT INT TERM
        run_check
        ;;
    calibrate)
        acquire_lock || exit 1
        trap release_lock EXIT INT TERM
        calibrate "$2"
        ;;
    run)
        while true; do
            if acquire_lock; then
                run_check
                release_lock
            fi
            sleep 30
        done
        ;;
    *)
        echo "Usage: $0 {run|check|calibrate BYTES}" >&2
        exit 1
        ;;
esac
