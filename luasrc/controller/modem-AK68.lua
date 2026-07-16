module("luci.controller.modem-AK68", package.seeall)
local fs = require "nixio.fs"
local nixio = require "nixio"

local function modem_log(component, message)
    local util = require "luci.util"
    luci.sys.call("logger -t ModemATSD " .. util.shellquote("[" .. component .. "] " .. message))
end
function index()
	entry({"admin", "modem-AK68"}, firstchild(), _("ATSD蜂窝"), 25).dependent = false
	local file = io.open("/tmp/modconf-AK68.conf", "r")
	local template_name = "zmode-AK68/net_status-AK68"
	local modem_cbi = "modem5700-AK68"  -- 默认设置为 modem5700-AK68
	if file then
		local content = file:read("*all")
		file:close()
		if content and (string.find(content, "RM520") or string.find(content, "NU313")) then
			template_name = "zmode-AK68/net_status_RM520-AK68"
			modem_cbi = "modem-AK68"
		elseif content and string.find(content, "MT5700") then
			template_name = "zmode-AK68/net_status_MT5700-AK68"
			modem_cbi = "modem5700-AK68" 
		end
	end
	entry({"admin", "modem-AK68", "Smstrun"}, template("zmode-AK68/settings"), _("短信转发"), 94).dependent = true
	entry({"admin", "modem-AK68", "smsc"}, template("zmode-AK68/smsc-AK68"), _("设备短信"), 95)
	entry({"admin", "modem-AK68", "nets"}, call("action_nets"), _("模组状态"), 97)
	entry({"admin", "modem-AK68", "traffic"}, template("zmode-AK68/traffic-AK68"), _("流量统计"), 96)
	entry({"admin", "modem-AK68", "modem"}, cbi(modem_cbi), _("模组设置"), 98) 
	entry({"admin", "modem-AK68", "backup"}, call("action_atsd_backup"), _("备份与恢复"), 99)
	entry({"admin", "modem-AK68", "debug"}, template("zmode-AK68/modem-debug-AK68"), _("模块调试"), 100)
	entry({"admin", "modem-AK68", "run_selftest"}, call("action_run_selftest")).leaf = true
	entry({"admin", "modem-AK68", "send_at"}, call("action_send_at")).leaf = true
	entry({"admin", "modem-AK68", "atsd_log"}, call("action_atsd_log")).leaf = true
	entry({"admin", "modem-AK68", "get_csq"}, call("action_get_csq"))
	entry({"admin", "modem-AK68", "status_refresh_config"}, call("action_status_refresh_config")).leaf = true
	entry({"admin", "modem-AK68", "traffic_stats"}, call("action_traffic_stats")).leaf = true
	entry({"admin", "modem-AK68", "traffic_config"}, call("action_traffic_config")).leaf = true
	entry({"admin", "modem-AK68", "traffic_calibrate"}, call("action_traffic_calibrate")).leaf = true
	entry({"admin", "modem-AK68", "smscs"}, call("action_smscs"))
    entry({"admin", "modem-AK68", "Smstrun", "set_token"}, call("set_token"), nil).leaf = true
    entry({"admin", "modem-AK68", "Smstrun", "set_title"}, call("set_title"), nil).leaf = true
    entry({"admin", "modem-AK68", "Smstrun", "check_status"}, call("check_status"), nil).leaf = true
    entry({"admin", "modem-AK68", "Smstrun", "redhis"}, call("redhis"), nil).leaf = true
end

function action_nets()
    local template = require "luci.template"
    local content = fs.readfile("/tmp/modconf-AK68.conf") or ""

    if content:find("RM520", 1, true) or content:find("NU313", 1, true) then
        template.render("zmode-AK68/net_status_RM520-AK68")
    elseif content:find("MT5700", 1, true) then
        template.render("zmode-AK68/net_status_MT5700-AK68")
    else
        template.render("zmode-AK68/net_status-AK68")
    end
end

local function is_mt5700()
    local content = fs.readfile("/tmp/modconf-AK68.conf") or ""
    return content:find("MT5700", 1, true) ~= nil
end

local function atsd_command(command)
    local shell_command = string.format("atsd_tools_cli -i cpe -c %q 2>&1", command)
    return luci.sys.exec(shell_command) or ""
end

local function parse_hex(value)
    if not value then
        return nil
    end

    -- Lua 5.1 on OpenWrt is commonly built with a 32-bit lua_Integer.
    -- tonumber(value, 16) then saturates at 0xffffffff even though
    -- lua_Number itself can exactly represent these modem counters.
    local result = 0
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    for i = 1, #value do
        local digit = tonumber(value:sub(i, i), 16)
        if not digit then
            return nil
        end
        result = result * 16 + digit
    end
    return result
end

function action_status_refresh_config()
    luci.http.prepare_content("application/json")
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        luci.http.status(405, "Method Not Allowed")
        luci.http.write_json({ success = false, error = "只允许 POST 请求。" })
        return
    end
    local value = tonumber(luci.http.formvalue("interval"))
    if value ~= 10 and value ~= 15 and value ~= 30 and value ~= 60 then
        luci.http.write_json({ success = false, error = "不支持的刷新频率。" })
        return
    end
    local uci = require("luci.model.uci").cursor()
    local old = uci:get("modem-AK68", "@ndis[0]", "status_refresh_interval") or "15"
    uci:set("modem-AK68", "@ndis[0]", "status_refresh_interval", tostring(value))
    uci:commit("modem-AK68")
    if old ~= tostring(value) then
        modem_log("模组状态", "刷新频率由 " .. old .. " 秒调整为 " .. value .. " 秒")
    end
    luci.http.write_json({ success = true, interval = value })
end

local function read_traffic_state()
    local state = {}
    local content = fs.readfile("/tmp/modem-traffic-AK68.state")
        or fs.readfile("/etc/modem-traffic-AK68.state") or ""
    for key, value in content:gmatch("([A-Z_]+)=([0-9]+)") do
        state[key] = tonumber(value)
    end
    return state
end

function action_traffic_stats()
    luci.http.prepare_content("application/json")
    if not is_mt5700() then
        luci.http.write_json({ success = false, error = "当前模组不是 MT5700，无法读取模组流量统计。" })
        return
    end

    local output = atsd_command("AT^DSFLOWQRY")
    local values = output:match("%^DSFLOWQRY:%s*([0-9A-Fa-f]+,[0-9A-Fa-f]+,[0-9A-Fa-f]+,[0-9A-Fa-f]+,[0-9A-Fa-f]+,[0-9A-Fa-f]+)")
    if not values then
        luci.http.write_json({ success = false, error = "模组未返回有效的流量统计。", raw = output })
        return
    end

    local fields = {}
    for value in values:gmatch("[^,]+") do
        fields[#fields + 1] = parse_hex(value)
    end
    local state = read_traffic_state()
    local uci = require("luci.model.uci").cursor()
    local limit_bytes = tonumber(uci:get("modem-AK68", "@ndis[0]", "traffic_limit_bytes")) or 107374182400
    local used_bytes = state.USED or 0
    luci.http.write_json({
        success = true,
        last_time = fields[1],
        last_tx = fields[2],
        last_rx = fields[3],
        total_time = fields[4],
        total_tx = fields[5],
        total_rx = fields[6],
        monthly_used = used_bytes,
        monthly_limit = limit_bytes,
        monthly_remaining = math.max(limit_bytes - used_bytes, 0),
        limit_enabled = uci:get("modem-AK68", "@ndis[0]", "traffic_limit_enable") == "1",
        billing_day = tonumber(uci:get("modem-AK68", "@ndis[0]", "traffic_billing_day")) or 1,
        blocked = state.BLOCKED == 1
    })
end

local function require_post()
    if luci.http.getenv("REQUEST_METHOD") == "POST" then
        return true
    end
    luci.http.status(405, "Method Not Allowed")
    luci.http.write_json({ success = false, error = "只允许 POST 请求。" })
    return false
end

function action_traffic_config()
    luci.http.prepare_content("application/json")
    local uci = require("luci.model.uci").cursor()
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        luci.http.write_json({
            success = true,
            enabled = uci:get("modem-AK68", "@ndis[0]", "traffic_limit_enable") == "1",
            limit_bytes = tonumber(uci:get("modem-AK68", "@ndis[0]", "traffic_limit_bytes")) or 107374182400,
            billing_day = tonumber(uci:get("modem-AK68", "@ndis[0]", "traffic_billing_day")) or 1
        })
        return
    end

    local old_enabled = uci:get("modem-AK68", "@ndis[0]", "traffic_limit_enable") or "0"
    local enabled = luci.http.formvalue("enabled") == "1" and "1" or "0"
    local limit_gb = tonumber(luci.http.formvalue("limit_gb"))
    local billing_day = tonumber(luci.http.formvalue("billing_day"))
    if not limit_gb or limit_gb <= 0 or limit_gb > 1048576 then
        luci.http.write_json({ success = false, error = "流量上限必须大于 0。" })
        return
    end
    if not billing_day or billing_day < 1 or billing_day > 28 or billing_day % 1 ~= 0 then
        luci.http.write_json({ success = false, error = "结算日只能设置为 1～28 日。" })
        return
    end

    uci:set("modem-AK68", "@ndis[0]", "traffic_limit_enable", enabled)
    uci:set("modem-AK68", "@ndis[0]", "traffic_limit_bytes", string.format("%.0f", limit_gb * 1073741824))
    uci:set("modem-AK68", "@ndis[0]", "traffic_billing_day", tostring(billing_day))
    uci:commit("modem-AK68")
    luci.sys.call("/usr/bin/modem-traffic-AK68.sh check >/dev/null 2>&1")
    modem_log("流量", "限额开关 -> " .. (enabled == "1" and "开启" or "关闭") .. "，上限 " .. limit_gb .. " GiB，结算日 " .. billing_day .. " 日" .. (old_enabled == enabled and "（参数更新）" or ""))
    luci.http.write_json({ success = true })
end

function action_traffic_calibrate()
    luci.http.prepare_content("application/json")
    if not require_post() then return end
    local used_gb = tonumber(luci.http.formvalue("used_gb"))
    if not used_gb or used_gb < 0 or used_gb > 1048576 then
        luci.http.write_json({ success = false, error = "已用流量必须是大于或等于 0 的数值。" })
        return
    end
    local bytes = string.format("%.0f", used_gb * 1073741824)
    local result = luci.sys.call("/usr/bin/modem-traffic-AK68.sh calibrate " .. bytes .. " >/dev/null 2>&1")
    modem_log("流量", result == 0 and ("手动校准已用流量为 " .. used_gb .. " GiB") or "手动校准失败")
    luci.http.write_json({ success = result == 0, error = result == 0 and nil or "校准失败，请确认模组在线。" })
end

function action_atsd_backup()
    local pid = nixio.getpid()
    local upload_path = "/tmp/atsd-settings-upload-" .. pid .. ".tar.gz"
    local output_path = "/tmp/atsd-settings-backup-" .. pid .. ".tar.gz"
    local upload_file
    local upload_size = 0
    local upload_error

    luci.http.setfilehandler(function(meta, chunk, eof)
        if chunk and #chunk > 0 and not upload_error then
            upload_size = upload_size + #chunk
            if upload_size > 2 * 1024 * 1024 then
                upload_error = "备份文件超过 2 MB。"
            else
                if not upload_file then upload_file = io.open(upload_path, "w") end
                if upload_file then upload_file:write(chunk) else upload_error = "无法保存上传文件。" end
            end
        end
        if eof and upload_file then upload_file:close(); upload_file = nil end
    end)

    local restore = luci.http.formvalue("restore")
    local backup = luci.http.formvalue("download")
    local message

    if backup then
        if luci.sys.call("/usr/bin/modem-backup-AK68.sh export " .. output_path .. " >/dev/null 2>&1") == 0 then
            modem_log("备份恢复", "导出 ATSD 设置成功")
            local content = fs.readfile(output_path)
            fs.remove(output_path)
            luci.http.header("Content-Disposition", 'attachment; filename="atsd-settings-' .. os.date("%Y%m%d-%H%M%S") .. '.tar.gz"')
            luci.http.prepare_content("application/gzip")
            luci.http.write(content or "")
            return
        end
        modem_log("备份恢复", "导出 ATSD 设置失败")
        message = "生成备份失败。"
    elseif restore then
        if upload_file then upload_file:close(); upload_file = nil end
        if upload_error then
            message = upload_error
        elseif not fs.access(upload_path) then
            message = "请选择需要恢复的备份文件。"
        elseif luci.sys.call("/usr/bin/modem-backup-AK68.sh restore " .. upload_path .. " >/dev/null 2>&1") == 0 then
            message = "ATSD 设置恢复成功，相关后台服务已重新加载，模组配置正在后台重新应用。"
            modem_log("备份恢复", "导入 ATSD 设置成功，正在重新应用模组配置")
        else
            message = "恢复失败：文件格式错误或包含不允许的内容。"
            modem_log("备份恢复", "导入 ATSD 设置失败")
        end
        fs.remove(upload_path)
    end

    luci.template.render("zmode-AK68/atsd-backup-AK68", { message = message })
end

function action_run_selftest()
    local output = luci.sys.exec("/usr/bin/atsd-test-AK68.sh 2>&1") or ""
    modem_log("功能测试", output:find("FAIL=0", 1, true) and "测试通过" or "测试存在失败项")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = output:find("FAIL=0", 1, true) ~= nil, output = output })
end

function action_send_at()
    luci.http.prepare_content("application/json")
    if not require_post() then return end

    local command = luci.http.formvalue("command") or ""
    command = command:gsub("^%s+", ""):gsub("%s+$", "")
    if command == "" then
        luci.http.write_json({ success = false, error = "AT 命令不能为空。" })
        return
    end
    if #command > 512 or command:find("[%z\1-\31\127]") then
        luci.http.write_json({ success = false, error = "AT 命令过长或包含非法控制字符。" })
        return
    end

    local util = require("luci.util")
    modem_log("AT调试", "执行命令: " .. command)
    local shell_command = "atsd_tools_cli -i cpe -c " .. util.shellquote(command) .. " 2>&1"
    local output = luci.sys.exec(shell_command) or ""
    local result = output:match("OK%s*$") and "成功" or "完成（未检测到结尾 OK）"
    modem_log("AT调试", "命令" .. result .. ": " .. command)
    luci.http.write_json({ success = true, output = output })
end

function action_atsd_log()
    luci.http.prepare_content("application/json")
    local lines = tonumber(luci.http.formvalue("lines")) or 200
    if lines ~= 100 and lines ~= 200 and lines ~= 500 then lines = 200 end
    local pattern = "atsd_tools|ModemATSD|MT5700_MODEM|RM520N_MODEM|modem-auto-schedule-AK68|modem-traffic-AK68|modem-led-schedule-AK68|modem-apply-config-AK68"
    local system_log = luci.sys.exec("logread 2>/dev/null | grep -E " .. require("luci.util").shellquote(pattern) .. " | tail -n " .. lines) or ""
    local sections = {}
    local files = {
        { "/tmp/moduleInit-AK68", "模组初始化日志 /tmp/moduleInit-AK68" },
        { "/tmp/moduleInit", "频段与锁定日志 /tmp/moduleInit" },
        { "/tmp/modem-apply-config-AK68.log", "配置恢复应用日志 /tmp/modem-apply-config-AK68.log" }
    }
    for _, item in ipairs(files) do
        local content = fs.readfile(item[1])
        if content and content ~= "" then
            if #content > 65536 then content = content:sub(-65536) end
            sections[#sections + 1] = "\n===== " .. item[2] .. " =====\n" .. content
        end
    end
    -- 历史文件放在前面、持续更新的 syslog 放在最后，前端才能跟随最新日志。
    sections[#sections + 1] = "\n===== ModemATSD 实时系统日志 =====\n" ..
        (system_log ~= "" and system_log or "暂无相关系统日志。\n")
    local output = table.concat(sections)
    luci.http.write_json({ success = true, output = output, timestamp = os.date("%Y-%m-%d %H:%M:%S") })
end

----------------短信转发
------------------------------------------------------------------------------------------------------------
function set_token()
    local token = luci.http.formvalue("ppsToken")
    if token then
        fs.writefile("/usr/bin/smstrun-AK68.conf", token)
        local output = luci.sys.exec("/usr/bin/setppstoken-AK68.sh")
        luci.http.prepare_content("application/json")
        luci.http.write_json({ result = true, output = output })
        luci.sys.exec("python3 /usr/bin/smstrun-AK68.py")
        modem_log("短信转发", token ~= "" and "转发开关 -> 开启" or "转发开关 -> 关闭")
    else
        luci.http.status(400, "Bad Request")
    end
end

function set_title()
    local title = luci.http.formvalue("smsTitle")
    if title then
        fs.writefile("/usr/bin/smstrun-title-AK68.conf", title)
        local output = luci.sys.exec("/usr/bin/setsmstitle-AK68.sh")
        luci.http.prepare_content("application/json")
        luci.http.write_json({ result = true, output = output })
        modem_log("短信转发", "推送标题已更新")
    else
        luci.http.status(400, "Bad Request")
    end
end


function check_status()
    local script = "/usr/bin/smstrun-AK68.py"
    local token_file = "/usr/bin/smstrun-AK68.conf"
    local title_file = "/usr/bin/smstrun-title-AK68.conf"
    local is_running = luci.sys.exec("pgrep -f " .. script) ~= ""
    local token_content = luci.sys.exec("cat " .. token_file) or ""
    local title_content = luci.sys.exec("cat " .. title_file) or ""
    luci.http.prepare_content("application/json")
    if is_running then
        luci.http.write_json({ status = "running", token = token_content, title = title_content })
    else
        luci.http.write_json({ status = "stopped" })
    end
end

function redhis()
    local output = luci.sys.exec("cat /tmp/smstrunsum-AK68.conf") or "" 
    if output == "" then
        output = "未发现转发记录，请核对。"
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = true, output = output })
end
-------------------------------------------------------------------------------
-----发短信
function action_smscs()
    luci.http.prepare_content("application/json")
    local operation = luci.http.formvalue("op") or "list"

    if operation == "list" then
        local jsonc = require "luci.jsonc"
        local output = luci.sys.exec("/usr/bin/sms_pdu_AK68.py --status all --format json 2>&1") or ""
        local result = jsonc.parse(output)
        if not result then
            luci.http.write_json({ success = false, messages = {}, error = "短信解析程序返回了无效数据。" })
            return
        end
        if result.errors and #result.errors > 0 then
            result.warning = table.concat(result.errors, "；")
        end
        luci.http.write_json(result)
        return
    end

    if not require_post() then return end

    local commands = {}
    if operation == "delete_all" then
        commands[1] = "AT+CMGD=0,4"
    elseif operation == "delete" then
        local raw_indexes = luci.http.formvalue("indexes") or ""
        local seen = {}
        for value in raw_indexes:gmatch("[^,]+") do
            if not value:match("^%d+$") then
                luci.http.write_json({ success = false, error = "短信编号格式无效。" })
                return
            end
            local index = tonumber(value)
            if not index or index < 0 or index > 65535 or seen[index] then
                luci.http.write_json({ success = false, error = "短信编号无效或重复。" })
                return
            end
            seen[index] = true
            commands[#commands + 1] = "AT+CMGD=" .. tostring(index)
        end
        if #commands == 0 or #commands > 255 then
            luci.http.write_json({ success = false, error = "没有可删除的短信编号。" })
            return
        end
    else
        luci.http.write_json({ success = false, error = "不支持的短信操作。" })
        return
    end

    for _, command in ipairs(commands) do
        local output = atsd_command(command)
        if not output:find("OK", 1, true) then
            luci.http.write_json({ success = false, error = "删除短信失败。", raw = output })
            return
        end
    end
    modem_log("短信", operation == "delete_all" and "已删除全部设备短信" or "已删除设备短信 " .. (luci.http.formvalue("indexes") or ""))
    luci.http.write_json({ success = true })
end
-----------------------------------------------------------------------------------
------------获取信号状态
function action_get_csq()
    local conf_file_path = "/tmp/modconf-AK68.conf"
    local conf_file = io.open(conf_file_path, "r")
    local modem_type = nil

    if conf_file then
        modem_type = conf_file:read("*line")
        conf_file:close()
    else
        error("Unable to open configuration file: " .. conf_file_path)
    end

    if modem_type:find("RM520") then
        io.popen("/usr/share/modem-AK68/zinfo-AK68.sh")
    elseif modem_type:find("MT5700") then
        io.popen("/usr/share/modem-AK68/zinfo5700-AK68.sh")
    else
        error("Unsupported modem type")
    end

    local file, file2
    local stat = "/tmp/cpe_cell-AK68.file"
    local stat2 = "/tmp/stsss.file"

    file = io.open(stat, "r")
    file2 = io.open(stat2, "r")

    if not file or not file2 then
        error("Error opening status files.")
    end

    local rv = {}
    rv["stsss"] = file2:read("*line")
    rv["modem"] = file:read("*line")
    rv["conntype"] = file:read("*line")
    rv["firmware"] = file:read("*line")
    rv["temper"] = file:read("*line")
    rv["date"] = file:read("*line")
	--------------------------------
	rv["simsel"] = file:read("*line")
	rv["cops"] = file:read("*line")
	rv["imei"] = file:read("*line")
	rv["imsi"] = file:read("*line")
	rv["iccid"] = file:read("*line")
	rv["phone"] = file:read("*line")
	--------------------------------
	rv["mode"] = file:read("*line")
	rv["per"] = file:read("*line")
	rv["rssi"] = file:read("*line")
	rv["rsrq"] = file:read("*line")
	rv["rscp"] = file:read("*line")
	rv["sinr"] = file:read("*line")
	-------------------------------
	rv["mcc"] = file:read("*line")
	rv["lac"] = file:read("*line")
	rv["cid"] = file:read("*line")
	rv["band"] = file:read("*line")
	rv["rfcn"] = file:read("*line")
	rv["pci"] = file:read("*line")
	rv["apn"] = file:read("*line")
	rv["down"] = file:read("*line")
	rv["up"] = file:read("*line")
	rv["qci"] = file:read("*line")
	rv["zbjh"] = file:read("*line")
	rv["r2cc"] = file:read("*line")
	rv["r3cc"] = file:read("*line")
	rv["cell1"] = file:read("*line")
	rv["cell2"] = file:read("*line")
	rv["cell3"] = file:read("*line")
	rv["cell4"] = file:read("*line")
	rv["cell5"] = file:read("*line")
	--------------------------------
	file:close()
    	file2:close()
	luci.http.prepare_content("application/json")
	luci.http.write_json(rv)
end
