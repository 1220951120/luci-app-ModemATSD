#!/bin/sh

# Apply restored UCI settings after the active modem initialization task releases
# its own lock. This runs asynchronously because a full apply can take a while.
rm -f /tmp/RF_Mode-AK68 /tmp/Band_LTE /tmp/Band_SA \
    /tmp/Band_LTE-AK68 /tmp/Band_SA-AK68 /tmp/Band_NSA-AK68 \
    /tmp/NR_Mode-AK68 /tmp/IMEI /tmp/IMEI-AK68 /tmp/freq.run /tmp/freq-AK68.run

for attempt in 1 2 3 4 5 6; do
    modem_type="$(cat /tmp/modconf-AK68.conf 2>/dev/null)"
    case "$modem_type" in
        *MT5700*) script=/usr/share/modem-AK68/MT5700-AK68.sh;;
        *RM520*) script=/usr/share/modem-AK68/rm520n-AK68.sh;;
        *RM500U*) script=/usr/share/modem-AK68/500U-AK68.sh;;
        *) script="";;
    esac

    if [ -n "$script" ]; then
        if echo "$modem_type" | grep -q 'MT5700'; then
            carrier="$(uci -q get modem-AK68.@ndis[0].carrier_aggregation)"
            case "$carrier" in
                0|1) atsd_tools_cli -i cpe -c "AT^NRRCCAPCFG=3,$carrier" >/dev/null 2>&1;;
            esac
        fi
    fi

    if [ -n "$script" ] && "$script"; then
        logger -t ModemATSD "[配置恢复] 已为 $modem_type 应用恢复的 ATSD 设置"
        exit 0
    fi
    sleep 10
done

logger -t ModemATSD "[配置恢复] 应用恢复的 ATSD 设置失败"
exit 1
