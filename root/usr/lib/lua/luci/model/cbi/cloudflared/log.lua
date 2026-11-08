local common = require "luci.cloudflared.common"
local jsonc = require "luci.jsonc"

m = Map("cloudflared",
	translate("Cloudflared Log"),
	translate("View plugin and core logs, with optional scheduled cleanup."))

m.apply_on_parse = false

if not m.uci:get("cloudflared", "log") then
	m.uci:set("cloudflared", "log", "log")
	m.uci:set("cloudflared", "log", "scheduled_clear", "1")
	m.uci:set("cloudflared", "log", "scheduled_clear_cron", "*/5 * * * *")
	m.uci:set("cloudflared", "log", "log_max_size", "1")
	m.uci:set("cloudflared", "log", "log_max_unit", "MB")
	m.uci:set("cloudflared", "log", "clear_at_stop", "1")
	m.uci:commit("cloudflared")
end

-- Migrate the untouched legacy log defaults to the new defaults.
do
	local c = m.uci:get_all("cloudflared", "log") or {}
	local clear = c.scheduled_clear or "0"
	local cronv = c.scheduled_clear_cron or "0 3 * * *"
	local size = c.log_max_size or "5"
	local unit = c.log_max_unit or "MB"
	local stop = c.clear_at_stop or "0"

	if clear == "0" and cronv == "0 3 * * *" and size == "5" and
	   unit == "MB" and stop == "0" then
		m.uci:set("cloudflared", "log", "scheduled_clear", "1")
		m.uci:set("cloudflared", "log", "scheduled_clear_cron", "*/5 * * * *")
		m.uci:set("cloudflared", "log", "log_max_size", "1")
		m.uci:set("cloudflared", "log", "log_max_unit", "MB")
		m.uci:set("cloudflared", "log", "clear_at_stop", "1")
		m.uci:commit("cloudflared")
	end
end

local i18n_json = jsonc.stringify({
	confirm = translate("Clear the current log?"),
	failed = translate("Failed to load log"),
	empty = translate("No log content yet."),
})

local function viewer_html(which, with_script)
	local prefix = "cf-log-" .. which
	local html = {}

	if which == "app" then
		html[#html + 1] = common.js_helpers()
	end

	html[#html + 1] = [[
<style>
.cf-log-toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:8px 0}
.cf-log-toolbar input.cf-log-filter{flex:1 1 240px;min-width:180px}
.cf-log-toolbar select{min-width:110px}
.cf-log-view{width:100%;height:62vh;min-height:420px;max-height:75vh;overflow:auto;white-space:pre-wrap;word-break:break-all;background:var(--surface-sunken,var(--v-surface-2,var(--s2,#fff)));color:var(--text,var(--v-text,#111));border:1px solid var(--hairline,var(--v-line-2,var(--line-2,#ccc)));border-radius:6px;padding:12px;font-family:monospace;font-size:14px;line-height:1.5;margin:0}
.cf-log-info{color:var(--text-muted,var(--v-text-3,var(--text-3,#666)));font-size:.9em}
</style>
]]

	html[#html + 1] = [[
<div class="cf-log-toolbar">
	<input type="text" id="]] .. prefix .. [[-filter" class="cbi-input-text cf-log-filter" placeholder="]] .. translate("Filter expression (grep -E)") .. [[">
	<select id="]] .. prefix .. [[-interval" class="cbi-input-select">
		<option value="0">]] .. translate("Disabled") .. [[</option>
		<option value="2000">2s</option>
		<option value="5000" selected>5s</option>
		<option value="10000">10s</option>
		<option value="30000">30s</option>
	</select>
	<button type="button" class="btn cbi-button" onclick="cfLogLoad(']] .. which .. [[')">]] .. translate("Refresh") .. [[</button>
	<button type="button" class="btn cbi-button cbi-button-reset" onclick="cfLogClear(']] .. which .. [[')">]] .. translate("Clear") .. [[</button>
	<button type="button" class="btn cbi-button" onclick="cfLogBottom(']] .. which .. [[')">]] .. translate("Scroll To Bottom") .. [[</button>
	<span id="]] .. prefix .. [[-info" class="cf-log-info"></span>
</div>
<pre id="]] .. prefix .. [[-view" class="cf-log-view"></pre>
]]

	if with_script then
		html[#html + 1] = [[
<script>
(function() {
	if (window.cfLogInit) return;
	window.cfLogInit = true;

	var I18N = ]] .. i18n_json .. [[;
	var timers = {};

	function view(which) { return document.getElementById("cf-log-" + which + "-view"); }
	function filter(which) { return document.getElementById("cf-log-" + which + "-filter"); }
	function interval(which) { return document.getElementById("cf-log-" + which + "-interval"); }
	function info(which) { return document.getElementById("cf-log-" + which + "-info"); }

	function visible(which) {
		var v = view(which);
		return v && v.offsetParent !== null && v.clientHeight > 0;
	}

	function load(which) {
		if (!visible(which)) return;
		var v = view(which);
		var f = filter(which);
		var atBottom = v.scrollTop + v.clientHeight >= v.scrollHeight - 24;
		var pattern = f ? f.value.replace(/^\s+|\s+$/g, "") : "";

		cfAction("get_log", { which: which, filter: pattern, lines: 800 }).then(function(r) {
			if (!r.ok) {
				v.textContent = r.message || I18N.failed;
				return;
			}
			v.textContent = r.log ? r.log : (I18N.empty + "\n" + (r.path || ""));
			var i = info(which);
			if (i) i.textContent = r.path || "";
			if (atBottom) v.scrollTop = v.scrollHeight;
		});
	}

	function restart(which) {
		if (timers[which]) {
			clearInterval(timers[which]);
			timers[which] = null;
		}
		var sel = interval(which);
		var ms = sel ? (parseInt(sel.value, 10) || 0) : 0;
		if (ms > 0)
			timers[which] = setInterval(function() { load(which); }, ms);
	}

	window.cfLogLoad = function(which) { load(which); };

	window.cfLogClear = function(which) {
		if (!confirm(I18N.confirm)) return;
		cfAction("clear_log", { which: which }).then(function() { load(which); });
	};

	window.cfLogBottom = function(which) {
		var v = view(which);
		if (v) v.scrollTop = v.scrollHeight;
	};

	["app", "core"].forEach(function(which) {
		var sel = interval(which);
		if (sel) sel.addEventListener("change", function() { restart(which); });
		var f = filter(which);
		if (f) f.addEventListener("keydown", function(ev) {
			if (ev.key === "Enter") { ev.preventDefault(); load(which); }
		});
		restart(which);
		load(which);
	});

	document.addEventListener("click", function(ev) {
		var a = ev.target && ev.target.closest ? ev.target.closest("ul.cbi-tabmenu li a") : null;
		if (a) {
			setTimeout(function() { load("app"); load("core"); }, 100);
		}
	});
})();
</script>
]]
	end

	return table.concat(html)
end

local s = m:section(NamedSection, "log", "log", translate("Log"))
s.addremove = false

s:tab("settings", translate("Log Settings"))
s:tab("app", translate("Plugin Log"))
s:tab("core", translate("Core Log"))

local cas = s:taboption("settings", Flag, "clear_at_stop", translate("Clear At Stop"))
cas.default = "1"
cas.rmempty = false

local sc = s:taboption("settings", Flag, "scheduled_clear", translate("Scheduled Cleanup"))
sc.default = "1"
sc.rmempty = false

local cron = s:taboption("settings", Value, "scheduled_clear_cron", translate("Cron Expression"),
	translate("Standard five-field cron expression, e.g. */5 * * * *."))
cron.default = "*/5 * * * *"
cron:depends("scheduled_clear", "1")
cron.rmempty = true
cron.validate = function(self, value)
	if not value or value == "" then
		return nil
	end
	if not value:match("^[%d%*/%,%-]+%s+[%d%*/%,%-]+%s+[%d%*/%,%-]+%s+[%d%*/%,%-]+%s+[%d%*/%,%-]+$") then
		return nil, translate("Invalid cron expression")
	end
	return value
end

local maxsize = s:taboption("settings", Value, "log_max_size", translate("Log Size Limit"),
	translate("Clean a log file when it exceeds this size at the scheduled time. 0 clears it every time."))
maxsize.default = "1"
maxsize.datatype = "uinteger"
maxsize.rmempty = false
maxsize.placeholder = "1"
maxsize:depends("scheduled_clear", "1")

local maxunit = s:taboption("settings", ListValue, "log_max_unit", translate("Size Unit"))
maxunit:value("KB", "KB")
maxunit:value("MB", "MB")
maxunit:value("GB", "GB")
maxunit.default = "MB"
maxunit.rmempty = false
maxunit:depends("scheduled_clear", "1")

local app_ui = s:taboption("app", DummyValue, "_app_log")
app_ui.rawhtml = true
app_ui.cfgvalue = function() return viewer_html("app", false) end

local core_ui = s:taboption("core", DummyValue, "_core_log")
core_ui.rawhtml = true
core_ui.cfgvalue = function() return viewer_html("core", true) end


-- ===== Hooks =====

function m.on_after_commit(self)
	self.uci:commit("cloudflared")
	common.update_log_cron()
end

return m
