#!/bin/sh

. "${IPKG_INSTROOT:-}/usr/bin/modem-led-control-AK68.sh"
echo "1、开启所有灯光"
echo "2、关闭所有灯光"
echo "3、恢复LED为正常状态"
read -p "请输入数字选择操作：" choice
case $choice in
    1)
        modem_led_set 1 cmode4
        modem_led_set 1 cmode5
        modem_led_set 1 wifi
        modem_led_set 1 status
        echo "已开启所有灯光，如要灯光显示真实状态，请重新运行命令并选择3！"
        echo "1" > /tmp/ledflag-AK68.conf
        ;;
    2)
        modem_led_set 0 cmode4
        modem_led_set 0 cmode5
        modem_led_set 0 wifi
        modem_led_set 0 status
        echo "已关闭所有灯光！请不要以为没通电。如要灯光显示真实状态，请重新运行命令并选择3！"
        echo "2" > /tmp/ledflag-AK68.conf
        ;;
    3)
        modem_led_set 1 wifi
        modem_led_set 1 status
        echo "已恢复灯光真实状态，5G和4G灯状态将稍后恢复。"
        rm /tmp/ledflag-AK68.conf
        ;;
    *)
        echo "无效的选择，请重新运行脚本并输入有效数字。"
        ;;
esac
