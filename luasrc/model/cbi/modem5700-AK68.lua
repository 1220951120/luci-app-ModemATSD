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
-- 检查配置文件内容并返回模块类型
local function get_module_type()
    local file = io.open("/tmp/modconf-AK68.conf", "r")
    local module_type = nil
    if file then
        local content = file:read("*all")
        file:close()
        if content and string.find(content, "MT5700") then
            module_type = "MT5700"
        end
    end
    return module_type
end

-- 根据模块类型设置标题
local module_type = get_module_type()
if not module_type then
    m = Map("modem-AK68", translate("AK68已断开或未接入！请接入后重试。"))
    return m
end

m = Map("modem-AK68", translate("AK68移动网络设置"))
section = m:section(TypedSection, "ndis", translate("AK68模组设置-巴龙MT5700M"))
section.anonymous = true
section.addremove = false

section:tab("general", translate("模组参数设置"))
section:tab("advanced", translate("高级设置"))



enable = section:taboption("general", Flag, "enable", translate("启用模块"))
enable.rmempty  = false
log_flag(enable, "启用模块")

simsel= section:taboption("general", ListValue, "simsel", translate("当前SIM卡"))
simsel:value("0", translate("外置SIM卡"))
simsel:value("1", translate("内置SIM1"))
--simsel:value("2", translate("内置SIM2"))
simsel.rmempty = true

------------
pincode = section:taboption("general", Value, "pincode", translate("PIN-密码"))
pincode.default=""
------
apnconfig = section:taboption("general", Value, "apnconfig", translate("APN配置"))
apnconfig.rmempty = true


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

local carrier_aggregation = section:taboption("advanced", Flag, "carrier_aggregation",
    translate("载波聚合"),
    translate("开启后允许模组使用多载波聚合。保存设置会软关软开模组射频，蜂窝网络将短暂断开并重新注册。"))
carrier_aggregation.rmempty = false

function carrier_aggregation.cfgvalue(self, section_id)
    local output = luci.sys.exec("atsd_tools_cli -i cpe -c 'AT^NRRCCAPQRY=3' 2>/dev/null") or ""
    local enabled = output:match("%^NRRCCAPQRY:%s*3,%s*(%d+)")
    if enabled == "0" or enabled == "1" then
        return enabled
    end
    return self.map:get(section_id, self.option) or "0"
end

function carrier_aggregation.write(self, section_id, value)
    value = value == "1" and "1" or "0"
    local current = self:cfgvalue(section_id)
    self.map:set(section_id, self.option, value)
    if current == value then
        return
    end

    local result = luci.sys.exec("atsd_tools_cli -i cpe -c 'AT^NRRCCAPCFG=3," .. value .. "' 2>&1") or ""
    if not result:match("OK%s*$") then
        modem_log("载波聚合", (value == "1" and "开启" or "关闭") .. "失败：模组未返回 OK")
        self.map.message = translate("载波聚合设置失败，模组未返回 OK。")
        return
    end

    luci.sys.call("atsd_tools_cli -i cpe -c 'AT+CFUN=0' >/dev/null 2>&1")
    luci.sys.call("sleep 2")
    luci.sys.call("atsd_tools_cli -i cpe -c 'AT+CFUN=1' >/dev/null 2>&1")
    modem_log("载波聚合", (value == "1" and "开启" or "关闭") .. "成功，已重启模组射频")
end

------------------------------------------------------------------------------------
luci.sys.exec("/usr/bin/LQXH-AK68.sh > /tmp/LQXH-AK68.file || echo '-' > /tmp/LQXH-AK68.file")--如果没有值要搞个-进去存着，不然这二逼LUA会报错
enable_imei2 = section:taboption("advanced", Flag, "enable_imei2", translate("显示邻区"))
enable_imei2.default = false
enable_imei2.rmempty = true
log_flag(enable_imei2, "显示邻区")

local function createSignalBar(rsrp_value)
    local bars = 10  -- 最大条数表示信号
    local percentage = math.min(100, math.max(0, (rsrp_value + 140) * 2))  -- 转换公式，确保范围在0-100
    local filledBars = math.floor((percentage / 100) * bars)
    local barGraph = string.rep(">", filledBars) .. string.rep("-", bars - filledBars)
    return string.format("[%s] %d%% (%d dBm)", barGraph, percentage, rsrp_value)
end

local function render_signal(name, line_number)
    local raw_value = luci.sys.exec("sed -n '" .. line_number .. "p' /tmp/LQXH-AK68.file")
    local mode = raw_value:match("模式(%w+)")
    local earfcn = raw_value:match("频点:(%d+)")
    local pci = raw_value:match("小区:(%d+)")
    local rsrp_value = tonumber(raw_value:match("信号:(%-?%d+)")) or -140
    local signalDisplay = createSignalBar(rsrp_value)
    return string.format("%s | 模式 %s | 频点： %s | 小区PCI： %s |  信号： %s", name, mode or "N/A", earfcn or "N/A", pci or "N/A", signalDisplay)
end

modify_imei2 = section:taboption("advanced", DummyValue, "modify_imei2", translate("邻信号1"))
modify_imei2.cfgvalue = function()
    return render_signal("节点", 1)
end
modify_imei2:depends("enable_imei2", "1")

modify_imei3 = section:taboption("advanced", DummyValue, "modify_imei3", translate("邻信号2"))
modify_imei3.cfgvalue = function()
    return render_signal("节点", 2)
end
modify_imei3:depends("enable_imei2", "1")

modify_imei4 = section:taboption("advanced", DummyValue, "modify_imei4", translate("邻信号3"))
modify_imei4.cfgvalue = function()
    return render_signal("节点", 3)
end
modify_imei4:depends("enable_imei2", "1")

modify_imei5 = section:taboption("advanced", DummyValue, "modify_imei5", translate("邻信号4"))
modify_imei5.cfgvalue = function()
    return render_signal("节点", 4)
end
modify_imei5:depends("enable_imei2", "1")

modify_imei6 = section:taboption("advanced", DummyValue, "modify_imei6", translate("邻信号5"))
modify_imei6.cfgvalue = function()
    return render_signal("节点", 5)
end
modify_imei6:depends("enable_imei2", "1")

modify_imei7 = section:taboption("advanced", DummyValue, "modify_imei7", translate("邻信号6"))
modify_imei7.cfgvalue = function()
    return render_signal("节点", 6)
end
modify_imei7:depends("enable_imei2", "1")

modify_imei8 = section:taboption("advanced", DummyValue, "modify_imei8", translate("邻信号7"))
modify_imei8.cfgvalue = function()
    return render_signal("节点", 7)
end
modify_imei8:depends("enable_imei2", "1")

modify_imei9 = section:taboption("advanced", DummyValue, "modify_imei9", translate("邻信号8"))
modify_imei9.cfgvalue = function()
    return render_signal("节点", 8)
end
modify_imei9:depends("enable_imei2", "1")

modify_imei10 = section:taboption("advanced", DummyValue, "modify_imei10", translate("邻信号9"))
modify_imei10.cfgvalue = function()
    return render_signal("节点", 9)
end
modify_imei10:depends("enable_imei2", "1")

modify_imei11 = section:taboption("advanced", DummyValue, "modify_imei11", translate("邻信号10"))
modify_imei11.cfgvalue = function()
    return render_signal("节点", 10)
end
modify_imei11:depends("enable_imei2", "1")
dataroaming = section:taboption("advanced", Flag, "datarroaming", translate("国际漫游"),"适用于行动网路漫游的数据体验，可能会产生高昂的费用。")
dataroaming.rmempty = true
log_flag(dataroaming, "国际漫游")
-----------------------------------------------------
--sim_card_stat = section:taboption("general", DummyValue, "sim_card_stat", translate("SIM卡状态"))
--sim_card_stat.value = luci.sys.exec("cat /tmp/simcardstat-AK68")
sim_card_stat = section:taboption("general", DummyValue, "sim_card_stat", translate("SIM卡状态"))
-- 执行命令并获取输出
local sim_status_output =luci.sys.exec("cat /tmp/simcardstat-AK68")
local sim_status_output = luci.sys.exec("atsd_tools_cli -i cpe -c 'AT^SIMSQ?' | awk '/^\\^SIMSQ:/ {split($0, a, \",\"); print a[2]}'")
sim_status_output = sim_status_output:match("%S+")
-- 根据输出解析 SIM 卡状态
local sim_status_description = "未获取到值,请刷新。"
if sim_status_output == "0" then
    sim_status_description = "状态码:0 -SIM卡未插入"
elseif sim_status_output == "1" then
    sim_status_description = "状态码:1 -SIM卡已插入"
elseif sim_status_output == "2" then
    sim_status_description = "状态码:2 -SIM卡被锁"
elseif sim_status_output == "3" then
    sim_status_description = "状态码:3-SIMLOCK 锁定(暂不支持上报)"
elseif sim_status_output == "10" then
    sim_status_description = "状态码:10-卡文件正在初始化 SIM Initializing"
elseif sim_status_output == "11" then
    sim_status_description = "状态码:11-SIN卡已经正常 （可接入网络）"
elseif sim_status_output == "12" then
    sim_status_description = "状态码:12 -SIM卡正常工作"
elseif sim_status_output == "98" then
    sim_status_description = "状态码:98 -卡物理失效 （PUK锁死或者卡物理失效）"
elseif sim_status_output == "99" then
    sim_status_description = "状态码:99 -卡移除 SIM removed"
elseif sim_status_output == "Note2" then
    sim_status_description = "状态码:Note2 -不支持虚拟SIM卡"
elseif sim_status_output == "100" then
    sim_status_description = "状态码:100 -卡错误（初始化过程中，卡失败）"
elseif sim_status_output == "" then
    sim_status_description = "未获取到值,请刷新。"
    sim_status_output = "未获取到值,请刷新。"
else

    sim_status_description = "状态码:"..sim_status_description.."  请参考AT手册"
end
-- 将描述设置为选项的值
sim_card_stat.value = sim_status_description

current_mod = section:taboption("general", Value, "current_mod", translate("当前模组"))
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
local poe_status = section:taboption("advanced", Button, "poe_control", translate("正在加载..."),"POE开关仅适用于WT9111主板以上")
function refreshPoeStatus(section)
    local value = luci.sys.exec("cat /sys/class/gpio/cpe1-pwr/value 2>/dev/null")
    value = value:match("%d") or "0"

    if value == "1" then
        poe_status.title = translate("POE供电")
        poe_status.inputtitle = translate("POE正在供电(点击关闭POE供电)")
    else
        poe_status.title = translate("POE供电")
        poe_status.inputtitle = translate("POE未供电(点击打开POE供电)")
    end
end
-----------------------------
enable_imei = section:taboption("advanced", Flag, "enable_imei", translate("ModifyI"))
enable_imei.default = false
enable_imei.rmempty = true
enable_imei:depends("simsel", "0")
log_flag(enable_imei, "修改IMEI")

modify_imei = section:taboption("advanced", Value, "modify_imei", translate("ModifyI"),translate("Warning! Warning! Warning! This is an internal engineering testing program, which is limited to testing whether the module is properly mounted. It is strictly prohibited to use it for other purposes, and the user shall bear all consequences arising from using it for other purposes on their own!"))
modify_imei.default = luci.sys.exec("atsd_tools_cli -i cpe -c AT+CGSN | sed -n '2p'")
modify_imei:depends("enable_imei", "1")
modify_imei.validate = function(self, value)
   if not value:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
       return nil, translate("IMEI必须是15位数字")
  end
  return value
end
-----------------------------------------------
smsen = section:taboption("general", Flag, "smsen", translate("短信开关"),translate("温馨提示：如果发送短信失败，请检查此处开关是否打开。某些SIM卡打开短信功能可能导致自动网络无法驻网5G,需要关闭短信功能!"))
--smsen.rmempty = true
smsen.default = 0
log_flag(smsen, "短信功能")
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

---------------------------------------
function poe_status.render(self, section)
    refreshPoeStatus(section)
    Button.render(self, section)
end

function poe_status.write(self, section)
    local value = luci.sys.exec("cat /sys/class/gpio/cpe1-pwr/value 2>/dev/null")
    value = value:match("%d") or "0"

    if value == "1" then
        os.execute("echo 0 > /sys/class/gpio/cpe1-pwr/value")
        modem_log("POE", "关闭供电")
    else
        os.execute("echo 1 > /sys/class/gpio/cpe1-pwr/value")
        modem_log("POE", "开启供电")
    end
    refreshPoeStatus(section)
end
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
-----------------------------------
--section:tab("ATA", translate("Internal testing"))
section:tab("ATA", translate("Internal testing"),translate("提示：该功能需要将模组设置-模组参数设置-短信开关勾选打开并提交生效后才能使用;Warning! Warning! Warning! This is an internal engineering testing program, which is limited to testing whether the module is properly mounted. It is strictly prohibited to use it for other purposes, and the user shall bear all consequences arising from using it for other purposes on their own!"))
local number5 = section:taboption("ATA", Value, "number1", translate("NUM"))
local take_btn = section:taboption("ATA", Button, "take", translate("Apply"))
local takeof_btn = section:taboption("ATA", Button, "takeof", translate("OFF"))

function take_btn.write(self, section)
    local number6 = number5:formvalue(section)
    if number6 == ""  then
        luci.http.write("<script>alert('输入框不能为空！');</script>")
    else
        local command = 'atsd_tools_cli -i cpe -c "' .. 'ATD' .. number6 .. ';"'
        local result = luci.sys.exec(command)
        if result and result:find("OK") then
            modem_log("内部测试", "拨号成功")
            luci.http.write("<script>alert('complete！');</script>")
        else
            modem_log("内部测试", "拨号失败")
            luci.http.write("<script>alert('Busy or EER！');</script>")
        end
        return nil
    end
    return nil
end

function takeof_btn.write()
    local result = luci.sys.exec('atsd_tools_cli -i cpe -c "ATH"')
    if result and result:find("OK") then
        modem_log("内部测试", "挂断成功")
        luci.http.write("<script>alert('complete！');</script>")
    else
        modem_log("内部测试", "挂断失败")
        luci.http.write("<script>alert('EER！');</script>")
    end
    return nil
end
------------
local apply = luci.http.formvalue("cbi.apply")
local sys = require "luci.sys"
local file = io.open("/tmp/modconf-AK68.conf", "r")
if apply then
    --function m.on_commit(map)
    --end
    if file then
        local content = file:read("*all")
        file:close()
        if content and string.find(content, "RM520") then
            --io.popen("/usr/share/modem-AK68/rm520n-AK68.sh &")
        elseif content and string.find(content, "MT5700") then
            io.popen("/usr/share/modem-AK68/MT5700-AK68.sh &")  
        end
    end
end
return m,m2
