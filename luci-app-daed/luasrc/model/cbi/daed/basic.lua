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
o.datatype = "uinteger"
o.rmempty = false

o = s:option(Value, "listen_addr",translate("Set the DAED listen address"))
o.default = '0.0.0.0:2023'
o.datatype = "hostport"
o.rmempty = false

o = s:option(Flag, "hijack_resolv", translate("Hijack /tmp/resolv.conf"),
	translate("Replace the system resolver with the WAN DNS servers while daed is running. Usually unnecessary."))
o.default = 0
o.rmempty = false

m.apply_on_parse = true
m.on_after_apply = function(self,map)
	if luci.sys.call("/etc/init.d/daed enabled") == 0 then
		luci.sys.exec("/etc/init.d/daed restart")
	else
		luci.sys.exec("/etc/init.d/daed stop")
	end
end

return m
