#!/bin/sh

BLUE4_DEVICE="BLUE4"
LEGACY_V4="BLUE4WAN"
LEGACY_V6="BLUE4WANV6"
network_changed=0
firewall_changed=0
dhcp_changed=0
legacy_v4_removed=0

log() {
	logger -t ModemATSD-blue4 "$*"
	echo "$*"
}

interface_uses_blue4() {
	local interface="$1"
	local devices device

	uci -q get "network.$interface" >/dev/null 2>&1 || return 1
	devices="$(uci -q get "network.$interface.device") $(uci -q get "network.$interface.ifname")"
	for device in $devices; do
		[ "$device" = "$BLUE4_DEVICE" ] && return 0
	done
	return 1
}

interface_matches_family() {
	local interface="$1"
	local family="$2"
	local proto

	proto="$(uci -q get "network.$interface.proto")"
	case "$family:$proto" in
		v6:dhcpv6|v6:6in4|v6:6to4|v6:6rd|v6:dslite|v6:map|v6:464xlat)
			return 0
			;;
		v6:static)
			[ -n "$(uci -q get "network.$interface.ip6addr")" ]
			return
			;;
		v6:*)
			return 1
			;;
		v4:dhcpv6|v4:6in4|v4:6to4|v4:6rd|v4:dslite|v4:map|v4:464xlat)
			return 1
			;;
		v4:*)
			return 0
			;;
	esac
}

find_blue4_interface() {
	local family="$1"
	local preferred interface

	[ "$family" = "v6" ] && preferred="wan6" || preferred="wan"
	if interface_uses_blue4 "$preferred" && interface_matches_family "$preferred" "$family"; then
		echo "$preferred"
		return 0
	fi

	for interface in $(uci -q show network | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
		case "$interface" in
			"$LEGACY_V4"|"$LEGACY_V6") continue ;;
		esac
		interface_uses_blue4 "$interface" || continue
		interface_matches_family "$interface" "$family" || continue
		echo "$interface"
		return 0
	done
	return 1
}

find_wan_zone() {
	uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='wan'$/\1/p" | head -n 1
}

zone_has_network() {
	local zone="$1"
	local interface="$2"

	uci -q get "firewall.$zone.network" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$interface"
}

add_zone_network() {
	local zone="$1"
	local interface="$2"

	[ -n "$zone" ] || return 0
	zone_has_network "$zone" "$interface" && return 0
	uci -q add_list "firewall.$zone.network=$interface"
	firewall_changed=1
}

remove_zone_network() {
	local zone="$1"
	local interface="$2"

	[ -n "$zone" ] || return 0
	while zone_has_network "$zone" "$interface"; do
		uci -q del_list "firewall.$zone.network=$interface" || break
		firewall_changed=1
	done
}

set_network_option() {
	local option="$1"
	local value="$2"

	[ "$(uci -q get "network.$option")" = "$value" ] && return 0
	uci -q set "network.$option=$value"
	network_changed=1
}

remove_legacy_interface() {
	local interface="$1"
	local zone="$2"

	if uci -q get "network.$interface" >/dev/null 2>&1; then
		uci -q delete "network.$interface"
		network_changed=1
		case "$interface" in
			"$LEGACY_V4") legacy_v4_removed=1 ;;
		esac
	fi
	if uci -q get "dhcp.$interface" >/dev/null 2>&1; then
		uci -q delete "dhcp.$interface"
		dhcp_changed=1
	fi
	remove_zone_network "$zone" "$interface"
}

ensure_legacy_interface() {
	local interface="$1"
	local proto="$2"
	local zone="$3"

	set_network_option "$interface" "interface"
	if uci -q show network | grep -q '^network\..*\.device='; then
		set_network_option "$interface.device" "$BLUE4_DEVICE"
		if uci -q get "network.$interface.ifname" >/dev/null 2>&1; then
			uci -q delete "network.$interface.ifname"
			network_changed=1
		fi
	else
		set_network_option "$interface.ifname" "$BLUE4_DEVICE"
	fi
	set_network_option "$interface.proto" "$proto"
	add_zone_network "$zone" "$interface"
}

if ! ip link show dev "$BLUE4_DEVICE" >/dev/null 2>&1; then
	log "Network interface BLUE4 not found; leaving network configuration unchanged."
	exit 0
fi

# The old marker lived outside /etc and was lost on firmware upgrades.  UCI
# state is now the idempotency guard, so remove the obsolete persistent file.
rm -f /usr/bin/blue4wan-AK68.conf

wan_zone="$(find_wan_zone)"
blue4_v4="$(find_blue4_interface v4)"
blue4_v6="$(find_blue4_interface v6)"

if [ -n "$blue4_v4" ]; then
	remove_legacy_interface "$LEGACY_V4" "$wan_zone"
else
	ensure_legacy_interface "$LEGACY_V4" dhcp "$wan_zone"
	blue4_v4="$LEGACY_V4"
fi

if [ -n "$blue4_v6" ]; then
	remove_legacy_interface "$LEGACY_V6" "$wan_zone"
else
	ensure_legacy_interface "$LEGACY_V6" dhcpv6 "$wan_zone"
	blue4_v6="$LEGACY_V6"
fi

[ "$network_changed" = 0 ] || uci -q commit network
[ "$dhcp_changed" = 0 ] || uci -q commit dhcp
[ "$firewall_changed" = 0 ] || uci -q commit firewall

if [ "$network_changed" = 1 ]; then
	ubus call network reload >/dev/null 2>&1
	# The two IPv4 DHCP interfaces share the BLUE4 kernel route and udhcpc pid
	# file.  Removing the legacy interface can therefore withdraw the default
	# route owned by the interface we keep while netifd still reports it as up.
	# Reconnect both address families after the one-time migration.  DHCPv6 relay
	# mode avoids a separate IA_NA address.  The IPv6 hotplug helper handles a
	# later upstream prefix change while keeping the stock mwan3 package intact.
	if [ "$legacy_v4_removed" = 1 ]; then
		ifdown "$blue4_v6" >/dev/null 2>&1
		ifdown "$blue4_v4" >/dev/null 2>&1
		ifup "$blue4_v4" >/dev/null 2>&1
		ifup "$blue4_v6" >/dev/null 2>&1
	fi
fi
if [ "$dhcp_changed" = 1 ]; then
	/etc/init.d/odhcpd reload >/dev/null 2>&1
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
fi
if [ "$firewall_changed" = 1 ]; then
	ubus call firewall reload >/dev/null 2>&1
fi

log "BLUE4 IPv4 interface: $blue4_v4; IPv6 interface: $blue4_v6"
