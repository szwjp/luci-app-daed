local sys  = require "luci.sys"
local http = require "luci.http"
local fs   = require "nixio.fs"

module("luci.controller.daed", package.seeall)

local LOG_FILE      = "/var/log/daed/daed.log"
local LOG_MAX_BYTES = 262144 -- 256 KiB，避免一次性把整个日志（默认上限 5MB）灌给浏览器

function index()
	if not fs.access("/etc/config/daed") then
		return
	end

	entry({"admin",  "services", "daed"}, alias("admin", "services", "daed", "setting"),_("DAED"), 58).dependent = true
	entry({"admin", "services", "daed", "setting"}, cbi("daed/basic"), _("Base Setting"), 1).leaf=true
	entry({"admin",  "services", "daed", "daed"}, template("daed/daed"), _("Dashboard"), 2).leaf = true
	entry({"admin", "services", "daed", "log"}, cbi("daed/log"), _("Logs"), 3).leaf = true
	entry({"admin", "services", "daed_status"}, call("act_status"))
	entry({"admin", "services", "daed", "get_log"}, call("get_log")).leaf = true
	-- post(...) 让 ucode/Lua dispatcher 统一做 POST + CSRF token 校验：
	-- GET → 405，token 不符 → 403，只有带正确 token 的 POST 才会进到函数体。
	entry({"admin", "services", "daed", "clear_log"}, post("clear_log")).leaf = true
end

function act_status()
	local e = { }
	e.running = sys.call("pidof daed >/dev/null") == 0
	http.prepare_content("application/json")
	http.write_json(e)
end

-- 只回纯文本：日志内容受外部输入影响（Host/UA/URL 等），按 text/html 返回
-- 再被前端 innerHTML 渲染就是存储型 XSS。
function get_log()
	local body = fs.readfile(LOG_FILE) or ""
	if #body > LOG_MAX_BYTES then
		body = body:sub(-LOG_MAX_BYTES)
	end

	http.prepare_content("text/plain; charset=utf-8")
	http.write(body)
end

-- 破坏性操作：POST + CSRF 校验由 entry 的 post() 完成（见 index()），
-- 到这里时请求已经是合法的 POST，不会再被第三方页面用 GET/img 触发。
function clear_log()
	local f = io.open(LOG_FILE, "w")
	if f then f:close() end

	http.prepare_content("application/json")
	http.write_json({ result = 0 })
end
