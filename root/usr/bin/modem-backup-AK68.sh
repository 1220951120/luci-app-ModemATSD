#!/bin/sh

allowed_path() {
    case "$1" in
        etc/config/modem-AK68|etc/modem-traffic-AK68.state|etc/modem-sms-forward-AK68.state|usr/bin/smstrun-AK68.conf|usr/bin/smstrun-title-AK68.conf|usr/bin/ledflagc.conf) return 0;;
        *) return 1;;
    esac
}

export_backup() {
    output="$1"
    set --
    for path in \
        etc/config/modem-AK68 \
        etc/modem-traffic-AK68.state \
        etc/modem-sms-forward-AK68.state \
        usr/bin/smstrun-AK68.conf \
        usr/bin/smstrun-title-AK68.conf \
        usr/bin/ledflagc.conf
    do
        [ -f "/$path" ] && set -- "$@" "$path"
    done
    [ "$#" -gt 0 ] || return 1
    (cd / && tar -czf "$output" "$@")
}

restore_backup() {
    archive="$1"
    work="/tmp/modem-backup-AK68.$$"
    mkdir -p "$work" || return 1
    trap 'rm -rf "$work"' EXIT INT TERM

    tar -tzf "$archive" > "$work/list" 2>/dev/null || return 1
    while IFS= read -r path; do
        path="${path#./}"
        allowed_path "$path" || return 1
    done < "$work/list"
    grep -qx 'etc/config/modem-AK68' "$work/list" || return 1

    tar -xzf "$archive" -C "$work" 2>/dev/null || return 1
    rm -f /etc/modem-traffic-AK68.state /etc/modem-sms-forward-AK68.state /usr/bin/smstrun-AK68.conf /usr/bin/smstrun-title-AK68.conf /usr/bin/ledflagc.conf
    while IFS= read -r path; do
        path="${path#./}"
        [ -f "$work/$path" ] && [ ! -L "$work/$path" ] || return 1
        mkdir -p "/${path%/*}"
        cp "$work/$path" "/$path" || return 1
    done < "$work/list"
    chmod 600 /etc/modem-traffic-AK68.state /etc/modem-sms-forward-AK68.state /usr/bin/smstrun-AK68.conf /usr/bin/smstrun-title-AK68.conf 2>/dev/null || true
    uci commit modem-AK68 2>/dev/null || true
    /etc/init.d/modem-traffic-AK68 restart 2>/dev/null || true
    /etc/init.d/modem-led-schedule-AK68 restart 2>/dev/null || true
    /etc/init.d/modem-sms-forward-AK68 restart 2>/dev/null || true
    /usr/bin/modem-apply-config-AK68.sh >/tmp/modem-apply-config-AK68.log 2>&1 &
}

case "$1" in
    export) export_backup "$2";;
    restore) restore_backup "$2";;
    *) echo "Usage: $0 {export OUTPUT|restore ARCHIVE}" >&2; exit 1;;
esac
