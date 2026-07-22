#!/bin/sh

echo "1、开启所有灯光"
echo "2、关闭所有灯光"
echo "3、恢复LED为正常状态"
read -p "请输入数字选择操作：" choice
case $choice in
    1)
        /usr/bin/modem-led-schedule-AK68.sh temporary-on && \
            echo "已开启所有灯光，如要灯光显示真实状态，请重新运行命令并选择3！"
        ;;
    2)
        /usr/bin/modem-led-schedule-AK68.sh temporary-off && \
            echo "已关闭所有灯光！请不要以为没通电。如要灯光显示真实状态，请重新运行命令并选择3！"
        ;;
    3)
        /usr/bin/modem-led-schedule-AK68.sh auto && \
            echo "已恢复灯光真实状态，5G和4G灯状态将稍后恢复。"
        ;;
    *)
        echo "无效的选择，请重新运行脚本并输入有效数字。"
        ;;
esac
