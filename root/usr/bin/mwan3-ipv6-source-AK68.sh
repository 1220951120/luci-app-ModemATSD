#!/bin/sh

# Keep the stock mwan3 IPv6 tracker in sync with an upstream CPE which replaces
# its SLAAC prefix without cycling the OpenWrt logical interface.  The stock
# tracker caches its source address, so reconnect only the affected IPv6
# interface after netifd shows both a new preferred address and an old
# deprecated address.

STATE_DIR="/tmp/mwan3-ipv6-source-AK68"
LOCK_FILE="/tmp/mwan3-ipv6-source-AK68.lock"
BLUE4_DEVICE="BLUE4"

log() {
	logger -t ModemATSD-mwan3-ipv6 "$*"
}

preferred_address() {
	ip -6 -o address show dev "$1" scope global 2>/dev/null |
		awk '$0 !~ / deprecated / {
			for (i = 1; i <= NF; i++) {
				if ($i == "inet6") {
					split($(i + 1), address, "/")
					print address[1]
					exit
				}
			}
		}'
}

has_deprecated_address() {
	ip -6 -o address show dev "$1" scope global 2>/dev/null |
		grep -q ' deprecated '
}

update_state() {
	local address

	address="$(preferred_address "$device")"
	[ -n "$address" ] && printf '%s\n' "$address" > "$state_file"
}

interface="$1"
device="$2"

case "$interface" in
	''|*[!A-Za-z0-9_.:@-]*) exit 0 ;;
esac

[ -x /usr/sbin/mwan3track ] || exit 0
[ "$(uci -q get "mwan3.$interface")" = "interface" ] || exit 0
[ "$(uci -q get "mwan3.$interface.enabled")" = "1" ] || exit 0
[ "$(uci -q get "mwan3.$interface.family")" = "ipv6" ] || exit 0
[ -n "$(uci -q get "mwan3.$interface.track_ip")" ] || exit 0

if [ -z "$device" ]; then
	. /lib/functions/network.sh
	network_flush_cache
	network_get_device device "$interface"
fi
[ "$device" = "$BLUE4_DEVICE" ] || exit 0

current_address="$(preferred_address "$device")"
[ -n "$current_address" ] || exit 0

mkdir -p "$STATE_DIR"
state_file="$STATE_DIR/$interface"
previous_address="$(cat "$state_file" 2>/dev/null)"

# A normal first address or a regular ifup is already handled by mwan3's own
# hotplug script.  Remember it without reconnecting.
if [ "$previous_address" = "$current_address" ] && ! has_deprecated_address "$device"; then
	exit 0
fi
printf '%s\n' "$current_address" > "$state_file"
has_deprecated_address "$device" || exit 0

# Prefix updates can emit several ifupdate events.  Only one worker is allowed
# to reconnect the logical interface; all state lives in tmpfs.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

sleep 2
current_address="$(preferred_address "$device")"
[ -n "$current_address" ] || exit 0
printf '%s\n' "$current_address" > "$state_file"
has_deprecated_address "$device" || exit 0

log "IPv6 prefix changed on $interface ($device); reconnecting this interface so stock mwan3 refreshes its source address"
ifdown "$interface" >/dev/null 2>&1
sleep 1
ifup "$interface" >/dev/null 2>&1

# The ifup event refreshes mwan3track.  Save the address netifd settled on so
# the resulting ifupdate event does not cause a second reconnect.
sleep 5
update_state
