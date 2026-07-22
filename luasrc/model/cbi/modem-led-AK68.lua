local m, section

local function modem_log(message)
    local util = require "luci.util"
    luci.sys.call("logger -t ModemATSD " .. util.shellquote("[LED] " .. message))
end

local function led_owner()
    local owner = luci.sys.exec("/usr/bin/modem-led-control-AK68.sh owner 2>/dev/null") or ""
    owner = owner:match("^%s*(.-)%s*$")
    return owner == "nu313" and "nu313" or "atsd"
end

local function owner_text()
    if led_owner() == "atsd" then
        return translate("ATSD（当前页面拥有 LED 控制权）")
    end
    return translate("NU313（ATSD 设置会保留，获得控制权后生效）")
end

local function run_led_action(action, label)
    if led_owner() ~= "atsd" then
        modem_log(label .. "未执行：当前控制权在 NU313")
        return
    end
    local result = luci.sys.call("/usr/bin/modem-led-schedule-AK68.sh " .. action .. " >/dev/null 2>&1")
    modem_log(label .. (result == 0 and "成功" or "失败"))
end

local function validate_led_time(self, value)
    local hour, minute = value:match("^(%d%d):(%d%d)$")
    if not hour or tonumber(hour) > 23 or tonumber(minute) > 59 then
        return nil, translate("请输入 HH:MM 格式的有效时间。")
    end
    return value
end

m = Map("modem-AK68", translate("LED灯光控制"),
    translate("ATSD 与 NU313 共用机身 LED。仅当前拥有控制权的应用会实际修改灯光；切换控制权后会自动应用对应应用的设置。"))

section = m:section(TypedSection, "ndis")
section.anonymous = true
section.addremove = false

local current_owner = section:option(DummyValue, "_led_owner", translate("当前 LED 控制权"))
function current_owner.cfgvalue()
    return owner_text()
end

local led_schedule_enable = section:option(Flag, "led_schedule_enable", translate("启用LED定时控制"),
    translate("到关闭时间后关闭所有灯光，到开启时间后恢复自动灯光控制。没有控制权时仅保存设置。"))
led_schedule_enable.default = "0"
led_schedule_enable.rmempty = false

local led_schedule_off = section:option(Value, "led_schedule_off", translate("定时关闭时间"))
led_schedule_off.default = "23:00"
led_schedule_off.validate = validate_led_time
led_schedule_off:depends("led_schedule_enable", "1")

local led_schedule_on = section:option(Value, "led_schedule_on", translate("定时开启时间"))
led_schedule_on.default = "07:00"
led_schedule_on.validate = validate_led_time
led_schedule_on:depends("led_schedule_enable", "1")

local temporary_off = section:option(Button, "_temporary_off", translate("临时关闭所有灯光"))
temporary_off.inputstyle = "remove"
function temporary_off.write()
    run_led_action("temporary-off", "临时关闭所有灯光")
end

local temporary_on = section:option(Button, "_temporary_on", translate("临时开启所有灯光"))
temporary_on.inputstyle = "apply"
function temporary_on.write()
    run_led_action("temporary-on", "临时开启所有灯光")
end

local automatic = section:option(Button, "_automatic", translate("恢复自动灯光控制"))
automatic.inputstyle = "apply"
function automatic.write()
    run_led_action("auto", "恢复自动灯光控制")
end

local permanent_off = section:option(Button, "_permanent_off", translate("永久关闭所有灯光"),
    translate("重启后仍保持关闭；恢复自动灯光控制可取消。"))
permanent_off.inputstyle = "remove"
function permanent_off.write()
    run_led_action("permanent-off", "永久关闭所有灯光")
end

return m
