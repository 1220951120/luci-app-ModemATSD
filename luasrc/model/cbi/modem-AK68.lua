local m, section, m2, s2

local function modem_log(component, message)
    local util = require "luci.util"
    luci.sys.call("logger -t ModemATSD " .. util.shellquote("[" .. component .. "] " .. message))
end

local function log_flag(option, label)
    local original_write = option.write
    local original_remove = option.remove
    function option.write(self, section_id, value)
        local old = tostring(self:cfgvalue(section_id) or self.default or self.disabled or "0")
        local result = original_write(self, section_id, value)
        if old ~= tostring(value) then
            modem_log("开关", label .. " -> " .. (tostring(value) == tostring(self.enabled or "1") and "开启" or "关闭"))
        end
        return result
    end
    function option.remove(self, section_id)
        local old = tostring(self:cfgvalue(section_id) or self.default or self.disabled or "0")
        local result = original_remove(self, section_id)
        local value = tostring(self.default or self.disabled or "0")
        if old ~= value then
            modem_log("开关", label .. " -> " .. (value == tostring(self.enabled or "1") and "开启" or "关闭"))
        end
        return result
    end
end
-- 检查配置文件内容
local function is_module_connected()
    local file = io.open("/tmp/modconf-AK68.conf", "r")
    if file then
        local content = file:read("*all")
        file:close()
        return content and (string.find(content, "RM520N") ~= nil or string.find(content, "NU313") ~= nil)
    end
    return false
end

-- 如果未连接模块，则只显示错误信息
if not is_module_connected() then
    m = Map("modem-AK68", translate("AK68已断开或未接入！请接入后重试。"))
    return m
end

m = Map("modem-AK68", translate("AK68移动网络设置"))
section = m:section(TypedSection, "ndis", translate("AK68模组设置-移远RM520N/NU313"))
section.anonymous = true
section.addremove = false
section:tab("general", translate("常规设置"))
section:tab("advanced", translate("高级设置"))

enable = section:taboption("general", Flag, "enable", translate("启用模块"))
enable.rmempty  = false
log_flag(enable, "启用模块")

simsel= section:taboption("general", ListValue, "simsel", translate("SIM卡选择"))
simsel:value("0", translate("外置SIM卡"))
simsel:value("1", translate("内置SIM1"))
--simsel:value("2", translate("内置SIM2"))
simsel.rmempty = true

pincode = section:taboption("general", Value, "pincode", translate("PIN密码"))
pincode.default=""
------
apnconfig = section:taboption("general", Value, "apnconfig", translate("APN接入点"))
apnconfig.rmempty = true

sim_card_stat = section:taboption("general", DummyValue, "sim_card_stat", translate("SIM卡状态"))
sim_card_stat.value = luci.sys.exec("cat /tmp/simcardstat-AK68")

current_mod = section:taboption("general", Value, "current_mod", translate("外接模组"))
current_mod.rmempty = true
current_mod.default = ""

function current_mod.cfgvalue(self, section)
    if nixio.fs.access("/tmp/modconf-AK68.conf") then
        return luci.sys.exec("cat /tmp/modconf-AK68.conf")
    else
        return "未知模块或未接入AK68模式"
    end
end

-- POE设置
local poe_status = section:taboption("general", Button, "poe_control", translate("正在加载..."))
function refreshPoeStatus(section)
    local value = luci.sys.exec("cat /sys/class/gpio/cpe-pwr/value 2>/dev/null")
    value = value:match("%d") or "0"

    if value == "0" then
        poe_status.title = translate("POE供电状态")
        poe_status.inputtitle = translate("POE正在供电(点击关闭POE供电)")
    else
        poe_status.title = translate("POE供电状态")
        poe_status.inputtitle = translate("POE未供电(点击打开POE供电)")
    end
end

function poe_status.render(self, section)
    refreshPoeStatus(section)
    Button.render(self, section)
end

function poe_status.write(self, section)
    local value = luci.sys.exec("cat /sys/class/gpio/cpe-pwr/value 2>/dev/null")
    value = value:match("%d") or "0"

    if value == "1" then
        os.execute("echo 0 > /sys/class/gpio/cpe-pwr/value")
        modem_log("POE", "关闭供电")
    else
        os.execute("echo 1 > /sys/class/gpio/cpe-pwr/value")
        modem_log("POE", "开启供电")
    end
    refreshPoeStatus(section)
end
section:tab("led", translate("LED灯光控制"),translate("说明：永久关闭灯光后,重启依然关闭,自定义LED行为不受本程序影响。"))
local function validate_led_time(self, value)
    local hour, minute = value:match("^(%d%d):(%d%d)$")
    if not hour or tonumber(hour) > 23 or tonumber(minute) > 59 then
        return nil, translate("请输入 HH:MM 格式的有效时间。")
    end
    return value
end

local led_schedule_enable = section:taboption("led", Flag, "led_schedule_enable", translate("启用LED定时控制"),
    translate("到关闭时间后执行“永久关闭所有灯光”，到开启时间后恢复自动灯光控制。"))
led_schedule_enable.default = "0"
led_schedule_enable.rmempty = false
log_flag(led_schedule_enable, "LED定时控制")

local led_schedule_off = section:taboption("led", Value, "led_schedule_off", translate("定时关闭时间"))
led_schedule_off.default = "23:00"
led_schedule_off.validate = validate_led_time
led_schedule_off:depends("led_schedule_enable", "1")

local led_schedule_on = section:taboption("led", Value, "led_schedule_on", translate("定时开启时间"))
led_schedule_on.default = "07:00"
led_schedule_on.validate = validate_led_time
led_schedule_on:depends("led_schedule_enable", "1")

local btn_send2 = section:taboption("led", Button, "cled2", translate("临时关闭所有灯光"))
function btn_send2.write()
    os.execute("echo 0 > /sys/class/leds/hc:blue:cmode4/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:cmode5/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:wifi/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:status/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:sig1/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:sig2/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:sig3/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:int/brightness")
    os.execute('echo "0" > /tmp/ledflag.conf')
    modem_log("LED", "临时关闭所有灯光")
end

local btn_send3 = section:taboption("led", Button, "cledl3", translate("临时开启所有灯光"))
function btn_send3.write()
    os.execute("echo 1 > /sys/class/leds/hc:blue:cmode4/brightness")
    os.execute("echo 1 > /sys/class/leds/hc:blue:cmode5/brightness")
    os.execute("echo 1 > /sys/class/leds/hc:blue:wifi/brightness")
    os.execute("echo 1 > /sys/class/leds/hc:blue:status/brightness")
    os.execute("echo 1 > /sys/class/leds/hc:blue:sig1/brightness")
    os.execute("echo 1 > /sys/class/leds/hc:blue:sig2/brightness")
    os.execute("echo 1 > /sys/class/leds/hc:blue:sig3/brightness")
    os.execute("echo 1 > /sys/class/leds/hc:blue:int/brightness")
    os.execute('echo "1" > /tmp/ledflag.conf')
    modem_log("LED", "临时开启所有灯光")
end

local btn_send5 = section:taboption("led", Button, "cledl5", translate("恢复自动灯光控制"))
function btn_send5.write()
    os.execute("echo 1 > /sys/class/leds/hc:blue:wifi/brightness")
    os.execute("echo 1 > /sys/class/leds/hc:blue:status/brightness")
    os.execute("rm -f /tmp/ledflag.conf")
    os.execute("rm -f /usr/bin/ledflagc.conf")
    modem_log("LED", "恢复自动灯光控制")
end

local btn_send4 = section:taboption("led", Button, "cledl4", translate("永久关闭所有灯光！"))
function btn_send4.write()
    os.execute("echo 0 > /sys/class/leds/hc:blue:cmode4/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:cmode5/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:wifi/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:status/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:sig1/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:sig2/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:sig3/brightness")
    os.execute("echo 0 > /sys/class/leds/hc:blue:int/brightness")
    os.execute('echo "0" > /tmp/ledflag.conf')
    os.execute('echo "0" > /usr/bin/ledflagc.conf')
    modem_log("LED", "永久关闭所有灯光")
end
------------------------------
----------------------
section:tab("ipv6", translate("IPV6操作"), translate("温馨提示：请选择你需要的IPV6执行结果后点击按钮完成设置。"))
local ipv6mode = section:taboption("ipv6", ListValue, "ipv6mode", translate("IPV6模式选择"))
ipv6mode:value("full", translate("打开IPV6通信"))
ipv6mode:value("half", translate("仅限CPE开IPV6"))
ipv6mode:value("off", translate("关闭IPV6通信"))
local ipv6btn = section:taboption("ipv6", Button, "ipv6btn", translate("执行选择模式"), translate("执行选择的模式，点击按钮即可生效，重启不会重新执行。"))
function ipv6btn.write(self, section)
    local mode = ipv6mode:formvalue(section)
    if not mode then
        luci.http.write("<script>alert('无效的模式选择！')</script>")
        return
    end
  
    if mode == "full" then
        command = '/usr/bin/full_ipv6-AK68.run'
        message = {
            done = translate("已完成打开IPV6动作，为了确保IPV6地址下发，建议使你的设备重新连接CPE以便于获取IPV6地址！"),
            fail = translate("执行失败：")
        }
    elseif mode == "half" then
        command = '/usr/bin/half_ipv6-AK68.run'
        message = {
            done = translate("已完成仅限CPE开IPV6，此模式你的设备不接入IPV6，但CPE本身可以通过IPV6通信！"),
            fail = translate("执行失败：")
        }
    elseif mode == "off" then
        command = '/usr/bin/turn_off_ipv6-AK68.run'
        message = {
            done = translate("已完成关闭所有IPV6通信，此模式CPE和你的设备都不通过IPV6通信！"),
            fail = translate("执行失败：")
        }
        luci.http.write("<script>alert('关闭IPV6需要等待数秒，请点击后等待完成，请不要刷新页面和操作其他！')</script>")
    end

    if command then
        local handle = io.popen(command, "r")
        local result = handle:read("*a")
        handle:close()

        if result:find("Done") then
            modem_log("IPv6", "模式 " .. mode .. " 应用成功")
            luci.http.write("<script>alert('" .. message.done .. "')</script>")
        else
            modem_log("IPv6", "模式 " .. mode .. " 应用失败")
            luci.http.write("<script>alert('" .. message.fail .. result .. "')</script>")
        end
    end
end

------------
local lock_schedule_enable = section:taboption("advanced", Flag, "lock_schedule_enable",
    translate("启用分时锁网"),
    translate("所有网络制式与锁网设置统一在分时规则中配置；00:00 到 00:00 表示全天锁网。未命中规则或关闭此功能时使用自动网络，相邻时间段会直接切换。"))
lock_schedule_enable.default = "0"
lock_schedule_enable.rmempty = false
log_flag(lock_schedule_enable, "分时锁网")

local lock_schedule_rules = section:taboption("advanced", Value, "lock_schedule_rules", translate("分时锁网规则"))
lock_schedule_rules.template = "zmode-AK68/lock-schedule-AK68"
lock_schedule_rules.rmempty = true
lock_schedule_rules:depends("lock_schedule_enable", "1")
lock_schedule_rules.validate = function(self, value)
    value = value or ""
    local util = require "luci.util"
    local result = luci.sys.exec("/usr/bin/modem-auto-schedule-AK68.sh --validate " .. util.shellquote(value) .. " 2>&1") or ""
    result = result:gsub("^%s+", ""):gsub("%s+$", "")
    if result == "OK" then
        return value
    end
    return nil, result ~= "" and result or translate("分时锁网规则校验失败")
end

dataroaming = section:taboption("advanced", Flag, "datarroaming", translate("国际漫游"),"适用于行动网路漫游的数据体验，可能会产生高昂的费用。")
dataroaming.rmempty = true
log_flag(dataroaming, "国际漫游")
enable_imei = section:taboption("advanced", Flag, "enable_imei", translate("修改IMEI"))
enable_imei.default = false
enable_imei:depends("simsel", "0")
log_flag(enable_imei, "修改IMEI")

modify_imei = section:taboption("advanced", Value, "modify_imei", translate("IMEI"))
modify_imei.default = luci.sys.exec("atsd_tools_cli -i cpe -c 'AT+CGSN'| grep -oE '[0-9]+'")
modify_imei:depends("enable_imei", "1")
modify_imei.validate = function(self, value)
    if not value:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
        return nil, translate("IMEI必须是15位数字")
    end
    return value
end

local apply = luci.http.formvalue("cbi.apply")
local sys = require "luci.sys"
local file = io.open("/tmp/modconf-AK68.conf", "r")
if apply then
    if file then
        local content = file:read("*all")
        file:close()
        if content and string.find(content, "RM520") then
            io.popen("/usr/share/modem-AK68/rm520n-AK68.sh &")
        elseif content and string.find(content, "RM500U") then
            io.popen("/usr/share/modem-AK68/500U-AK68.sh &")  
        end
    end
end
return m,m2
