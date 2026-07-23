#!/bin/sh

. "${IPKG_INSTROOT:-}/usr/bin/modem-led-control-AK68.sh"
# 检查是否已经有锁文件存在
lock_file="/var/run/devck_status-AK68.lock"
exec 200>$lock_file
flock -n 200 || exit 1
while true
do
    # 检查 /tmp/devck.conf 文件内容
    sleep 15
    if ! modem_led_atsd_link_up; then
        modem_led_write_atsd_state "AK68套件断开或未接入！"
        echo "设备检测中..." > /tmp/devck.conf
        modem_led_set 0 cmode5
        modem_led_set 0 cmode4
        continue
    fi
    if [ -f /tmp/devck.conf ] && grep -q "已有设备" /tmp/devck.conf; then
        sleep 15
        continue
    fi

    if modem_led_atsd_ping 192.168.225.1 > /dev/null 2>&1; then
        cp -f /usr/share/modem-AK68/C-RM520N /etc/config/atsd_tools
        /etc/init.d/atsd_tools restart
        sleep 1
        output=$(atsd_tools_cli -i cpe -c "ATI")
        if echo "$output" | grep -q "RM520"; then
            echo "已有设备" > /tmp/devck.conf
            modem_led_write_atsd_state "RM520N"
            sleep 2
            /usr/share/modem-AK68/rm520n-AK68.sh &
        else
            echo "检测到IP 192.168.225.1,但该IP不是X62模组！已跳过。"
            if modem_led_atsd_ping 192.168.8.1 > /dev/null 2>&1; then
                cp -f /usr/share/modem-AK68/C-MT5700 /etc/config/atsd_tools
                /etc/init.d/atsd_tools restart
                sleep 1
                output=$(atsd_tools_cli -i cpe -c "ATI")
                if echo "$output" | grep -q "MT5700"; then
                    echo "已有设备" > /tmp/devck.conf
                    modem_led_write_atsd_state "MT5700"
                    sleep 2
                    /usr/share/modem-AK68/MT5700-AK68.sh &
                else
                    echo "检测到IP 192.168.8.1,但该IP不是巴龙模组！已跳过。"
                    sleep 1
                    continue
                fi
            else
                modem_led_write_atsd_state "AK68套件断开或未接入！"
                modem_led_set 0 cmode5
                modem_led_set 0 cmode4
                sleep 1
                continue
            fi
        fi
    elif modem_led_atsd_ping 192.168.8.1 > /dev/null 2>&1; then
            cp -f /usr/share/modem-AK68/C-MT5700 /etc/config/atsd_tools
            /etc/init.d/atsd_tools restart
            sleep 1
            output=$(atsd_tools_cli -i cpe -c "ATI")
            if echo "$output" | grep -q "MT5700"; then
                echo "已有设备" > /tmp/devck.conf
                modem_led_write_atsd_state "MT5700"
                sleep 2
                /usr/share/modem-AK68/MT5700-AK68.sh &
            else
                echo "检测到IP 192.168.8.1,但该IP不是巴龙模组！已跳过。"
                sleep 1
                continue
            fi
    elif modem_led_atsd_ping 192.168.200.1 > /dev/null 2>&1; then
            cp -f /usr/share/modem-AK68/C-NU313 /etc/config/atsd_tools
            /etc/init.d/atsd_tools restart
            sleep 1
            output=$(atsd_tools_cli -i cpe -c "ATI")
            if echo "$output" | grep -Eiq "NU313|UNISOC|UIS"; then
                echo "已有设备" > /tmp/devck.conf
                modem_led_write_atsd_state "NU313"
            else
                echo "检测到IP 192.168.200.1,但该IP不是NU313模组！已跳过。"
                sleep 1
                continue
            fi
    else
        modem_led_write_atsd_state "AK68套件断开或未接入！"
        modem_led_set 0 cmode5
        modem_led_set 0 cmode4
        sleep 1
        continue
    fi
done
# 释放锁
flock -u 200
