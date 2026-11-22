local http = require "luci.http"

local m, s ,o

m = Map("daed")
m.title = translate("DAED")
m.description = translate("DAE is a Linux high-performance transparent proxy solution based on eBPF, And DAED is a modern dashboard for dae.")

m:section(SimpleSection).template = "daed/daed_status"

s = m:section(TypedSection, "daed", translate("Global Settings"))
s.addremove = false
s.anonymous = true

o = s:option(Flag,"enabled",translate("Enable"))
o.default = 0
o.rmempty = false

o = s:option(Value, "log_maxbackups", translate("Logfile retention count"))
o.default = 1
o.datatype = "uinteger"
o.rmempty = false

o = s:option(Value, "log_maxsize", translate("Logfile Max Size (MB)"))
o.default = 5
o.datatype = "range(1,100)"
o.rmempty = false

o = s:option(Flag, "delay_start", translate("Wait for WAN before start"),
	translate("Delay the boot-time start until the WAN interface is up. PPPoE usually needs about 20 seconds."))
o.default = 1
o.rmempty = false

o = s:option(Value, "wan_timeout", translate("WAN wait timeout (seconds)"))
o.default = 60
o.datatype = "range(0,600)"
o.rmempty = false
o:depends("delay_start", "1")

o = s:option(Value, "listen_addr",translate("Set the DAED listen address"))
o.default = '0.0.0.0:2023'
o.datatype = "hostport"
o.rmempty = false

o = s:option(Flag, "hijack_resolv", translate("Hijack /tmp/resolv.conf"),
	translate("Replace the system resolver with the WAN DNS servers while daed is running. Usually unnecessary."))
o.default = 0
o.rmempty = false

o = s:option(Flag, "geo_update", translate("Update geo data periodically"),
	translate("Refresh geoip.dat / geosite.dat on a schedule. daed only reads them at startup."))
o.default = 0
o.rmempty = false

o = s:option(Value, "geo_update_cron", translate("Geo update schedule (cron)"))
o.default = "0 3 * * 1"
o.placeholder = "0 3 * * 1"
o.rmempty = false
o:depends("geo_update", "1")

m.apply_on_parse = true

-- 只有会影响 daed 启动参数的选项变化时才重启进程：只改 geo 周期/日志保留数量
-- 也重启会白白中断连接（审查 N05）。
local restart_keys = {
	"enabled", "listen_addr", "log_maxbackups", "log_maxsize",
	"delay_start", "wan_timeout", "hijack_resolv",
}
local restart_before = {}

m.on_before_commit = function(self)
	for _, k in ipairs(restart_keys) do
		restart_before[k] = tostring(self.uci:get("daed", "config", k) or "")
	end
end

m.on_after_apply = function(self)
	local changed = false
	for _, k in ipairs(restart_keys) do
		-- 复选框未勾选时表单里没有该键，回退到已提交的 UCI 值
		local new = http.formvalue("cbid.daed." .. k)
		if new == nil then
			new = self.uci:get("daed", "config", k) or ""
		end
		if tostring(new) ~= (restart_before[k] or "") then
			changed = true
			break
		end
	end

	if changed then
		if luci.sys.call("/etc/init.d/daed enabled") == 0 then
			luci.sys.exec("/etc/init.d/daed restart")
		else
			luci.sys.exec("/etc/init.d/daed stop")
		end
	end

	-- geo 周期/开关改了要立刻反映到 crontab（这个服务重启很便宜）
	luci.sys.exec("/etc/init.d/daed-geo-update restart")
end

return m
