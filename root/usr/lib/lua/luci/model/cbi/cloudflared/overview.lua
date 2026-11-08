local sys = require "luci.sys"
local fs = require "nixio.fs"
local uci = require "luci.model.uci".cursor()
local common = require "luci.cloudflared.common"
local xml = require "luci.xml"
local jsonc = require "luci.jsonc"

m = Map("cloudflared",
	translate("Cloudflared Tunnel"),
	translate("Configure Cloudflare Tunnel"))

m.apply_on_parse = false

local function main_restart_signature(cursor)
	local parts = {}
	for _, key in ipairs({ "base_path", "cloudflared_path", "cert_path" }) do
		parts[#parts + 1] = key .. "=" .. tostring(cursor:get("cloudflared", "main", key) or "")
	end
	return table.concat(parts, "\n")
end

local main_before = main_restart_signature(uci)

local base = uci:get("cloudflared", "main", "base_path") or "/opt/cloudflare"
local bin = common.find_binary()
local version = ""
if bin then
	version = (common.run("version")) or ""
	version = version:match("[0-9]+%.[0-9]+%.[0-9]+") or version:gsub("%s+$", "")
end

local tunnel_count = 0
uci:foreach("cloudflared", "tunnel", function()
	tunnel_count = tunnel_count + 1
end)

local running = sys.call("pgrep -f 'cloudflared.*tunnel run' >/dev/null 2>&1") == 0
local service_enabled = fs.access("/etc/rc.d/S99cloudflared") and true or false

local warnings = ""
if not fs.access(base) then
	warnings = warnings .. "<br><span style='color:red'>⚠ " .. translate("Base path not found") .. "</span>"
end
if not bin then
	warnings = warnings .. "<br><span style='color:red'>⚠ " .. translate("Cloudflared binary missing") .. "</span>"
end
if tunnel_count == 0 then
	warnings = warnings .. "<br><span style='color:#e67e22'>⚠ " .. translate("No tunnel configured") .. "</span>"
end

local stats_html = [[
<style>
.cf-stat-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px;margin:12px 0 4px}
@media (max-width:720px){.cf-stat-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}
.cf-stat{background:rgba(128,128,128,.1);border:1px solid rgba(128,128,128,.18);border-radius:6px;padding:8px 10px;min-width:0}
.cf-stat-label{font-size:.78em;color:#888;margin-bottom:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cf-stat-value{font-size:1.02em;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
</style>
<div class="cf-stat-grid">
	<div class="cf-stat">
		<div class="cf-stat-label">]] .. translate("Connection") .. [[</div>
		<div class="cf-stat-value" style="color:]] .. (running and "green" or "red") .. [[">]] .. (running and translate("Running") or translate("Stopped")) .. [[</div>
	</div>
	<div class="cf-stat">
		<div class="cf-stat-label">]] .. translate("Tunnels") .. [[</div>
		<div class="cf-stat-value">]] .. tostring(tunnel_count) .. [[</div>
	</div>
	<div class="cf-stat">
		<div class="cf-stat-label">]] .. translate("Version") .. [[</div>
		<div class="cf-stat-value" title="]] .. xml.pcdata(version ~= "" and version or "—") .. [[">]] .. xml.pcdata(version ~= "" and version or "—") .. [[</div>
	</div>
	<div class="cf-stat">
		<div class="cf-stat-label">]] .. translate("Core Status") .. [[</div>
		<div class="cf-stat-value" style="color:]] .. (bin and "green" or "red") .. [[">]] .. (bin and translate("Installed") or translate("Missing")) .. [[</div>
	</div>
</div>
]]

m.description = warnings ~= "" and (warnings:gsub("^<br>", "")) or ""

local jssec = m:section(SimpleSection)
jssec.anonymous = true
local jso = jssec:option(DummyValue, "_js")
jso.rawhtml = true
jso.cfgvalue = function() return common.js_helpers() .. stats_html end


-- ===== Top control grid: service control (left) + cloudflared core (right) =====

local arch = (sys.exec("uname -m") or ""):gsub("%s+$", "")
local asset_info = common.core_asset()
local dl_asset = asset_info.asset or ""
local dl_url = asset_info.url or ""

local top = m:section(SimpleSection)
top.anonymous = true
local top_ui = top:option(DummyValue, "_top_ui")
top_ui.rawhtml = true
top_ui.cfgvalue = function()
	local i18n_json = jsonc.stringify({
		starting = translate("Preparing download..."),
		downloading = translate("Downloading Cloudflared core..."),
		verifying = translate("Verifying binary..."),
		done = translate("Cloudflared core is up to date."),
		failed = translate("Download failed"),
		missing = translate("Cloudflared core not found. Click \"Install / Update\" to download it."),
		install = translate("Install / Update"),
		check = translate("Check Status"),
		checking = translate("Checking for updates..."),
		uptodate = translate("Already the latest version, no update needed."),
		timeout = translate("Install timed out. Check the log for details."),
		enable_boot = translate("Enable on boot"),
		service_failed = translate("Failed to update auto-start setting"),
		download = translate("Download Core"),
		upload = translate("Upload Core"),
		uploading = translate("Uploading..."),
		upload_failed = translate("Upload failed"),
		upload_done = translate("Upload complete, reloading..."),
		unsupported = translate("Unsupported architecture"),
		start = translate("Start"),
		stop = translate("Stop"),
		restart = translate("Restart"),
		service = translate("Service Control"),
		core = translate("Cloudflared Core"),
		architecture = translate("Architecture"),
		current = translate("Current version"),
		binary = translate("Binary"),
	})

	local html = {}

	html[#html + 1] = [[
<style>
.cf-top-grid{display:flex;flex-wrap:wrap;gap:16px;margin:4px 0 18px}
.cf-top-col{flex:1 1 320px;min-width:280px;box-sizing:border-box;border:1px solid rgba(128,128,128,.25);border-radius:8px;padding:14px 16px}
.cf-top-col h3{margin:0 0 12px;font-size:1.05em}
.cf-svc-row{display:flex;flex-wrap:wrap;gap:8px}
.cf-svc-row .btn{margin:0}
.cf-enable-row{display:flex;align-items:center;gap:8px;margin-top:14px;font-size:.95em}
.cf-enable-row input{margin:0}
.cf-progress-wrap{margin-top:16px}
.cf-progress-head{display:flex;justify-content:space-between;gap:8px;font-size:.9em;margin-bottom:6px;color:#777}
.cf-progress{position:relative;height:14px;background:rgba(128,128,128,.22);border-radius:7px;overflow:hidden}
.cf-progress-bar{height:100%;width:0;border-radius:7px;background:linear-gradient(90deg,#1e88e5,#42a5f5);transition:width .35s ease}
.cf-progress-bar.cf-indeterminate{position:absolute;width:35%!important;animation:cf-slide 1.2s ease-in-out infinite}
.cf-progress-bar.cf-done{width:100%!important;background:#43a047}
.cf-progress-bar.cf-fail{width:100%!important;background:#e53935}
@keyframes cf-slide{0%{left:-35%}100%{left:100%}}
.cf-core-meta{line-height:1.9;margin-bottom:12px}
.cf-core-meta code{word-break:break-all}
.cf-core-out{white-space:pre-wrap;margin-top:10px}
.cf-core-out:empty{display:none}
</style>
<div class="cf-top-grid">
	<div class="cf-top-col">
		<h3>]] .. translate("Service Control") .. [[</h3>
		<div class="cf-svc-row">
			<button type="button" class="btn cbi-button cbi-button-apply" onclick="cfService('start')">]] .. translate("Start") .. [[</button>
			<button type="button" class="btn cbi-button cbi-button-reset" onclick="cfService('stop')">]] .. translate("Stop") .. [[</button>
			<button type="button" class="btn cbi-button cbi-button-reload" onclick="cfService('restart')">]] .. translate("Restart") .. [[</button>
		</div>
		<div class="cf-enable-row">
			<input type="checkbox" id="cf-service-enabled" class="cbi-input-checkbox"]] .. (service_enabled and " checked" or "") .. [[>
			<label for="cf-service-enabled">]] .. translate("Enable on boot") .. [[</label>
		</div>
	</div>
	<div class="cf-top-col">
		<h3>]] .. translate("Cloudflared Core") .. [[</h3>
		<div class="cf-core-meta">
			<div>]] .. translate("Architecture") .. [[: <strong>]] .. xml.pcdata(arch ~= "" and arch or "—") .. [[</strong></div>
			<div>]] .. translate("Current version") .. [[: <strong>]] .. xml.pcdata(version ~= "" and version or "—") .. [[</strong></div>
			<div>]] .. translate("Binary") .. [[: <code>]] .. xml.pcdata(bin or "—") .. [[</code></div>
		</div>
		<div class="cf-svc-row">
			<button type="button" class="btn cbi-button cbi-button-apply" onclick="cfCoreInstall()">]] .. translate("Install / Update") .. [[</button>
			<button type="button" class="btn cbi-button" onclick="cfCoreStatus()">]] .. translate("Check Status") .. [[</button>
			]] .. (dl_url ~= "" and
				('<a class="btn cbi-button" href="' .. xml.pcdata(dl_url) ..
				 '" target="_blank" rel="noopener" download title="' ..
				 xml.pcdata(dl_asset) .. '">' .. translate("Download Core") .. "</a>") or
				('<button type="button" class="btn cbi-button" disabled title="' ..
				 translate("Unsupported architecture") .. '">' ..
				 translate("Download Core") .. "</button>")) .. [[
			<input type="file" id="cf-core-file" style="display:none">
			<button type="button" class="btn cbi-button" onclick="document.getElementById('cf-core-file').click()">]] .. translate("Upload Core") .. [[</button>
		</div>
		<pre id="cf-core-out" class="cf-core-out"></pre>
		<div id="cf-progress-wrap" class="cf-progress-wrap" style="display:none">
			<div class="cf-progress-head">
				<span id="cf-progress-label"></span>
				<span id="cf-progress-pct"></span>
			</div>
			<div class="cf-progress"><div id="cf-progress-bar" class="cf-progress-bar"></div></div>
		</div>
	</div>
</div>
<script>
(function() {
	var I18N = ]] .. i18n_json .. [[;
	var wrap = document.getElementById("cf-progress-wrap");
	var labelEl = document.getElementById("cf-progress-label");
	var pctEl = document.getElementById("cf-progress-pct");
	var bar = document.getElementById("cf-progress-bar");
	var pollTimer = null;
	var pollCount = 0;
	var tracking = false;

	function setBar(mode, pct) {
		if (!bar) return;
		bar.className = "cf-progress-bar";
		if (mode === "indeterminate") {
			bar.className += " cf-indeterminate";
			bar.style.width = "";
			if (pctEl) pctEl.textContent = "";
		} else {
			bar.style.width = (pct || 0) + "%";
			if (mode === "done") bar.className += " cf-done";
			if (mode === "fail") bar.className += " cf-fail";
			if (pctEl) pctEl.textContent = (pct || 0) > 0 ? (pct + "%") : "";
		}
	}

	function showProgress(label, mode, pct) {
		if (!wrap) return;
		wrap.style.display = "block";
		if (labelEl) labelEl.textContent = label || "";
		setBar(mode, pct);
	}

	function hideProgress() {
		if (wrap) wrap.style.display = "none";
	}

	window.cfService = window.cfService || function(op) {
		cfAction("service", { op: op }).then(function(r) {
			alert(r.message || (r.ok ? "OK" : "Failed"));
			if (r.ok) location.reload();
		});
	};

	function applyStatus(r) {
		var state = r.state || "idle";
		if (state === "starting" || state === "downloading" || state === "verifying") {
			tracking = true;
			showProgress(state === "starting" ? I18N.starting :
				(state === "downloading" ? I18N.downloading : I18N.verifying), "indeterminate", 0);
		} else if (state === "done") {
			if (tracking) {
				tracking = false;
				showProgress(I18N.done, "done", 100);
				setTimeout(hideProgress, 5000);
			} else {
				hideProgress();
			}
		} else if (state === "failed") {
			if (tracking) {
				tracking = false;
				showProgress(I18N.failed + (r.message ? (": " + r.message) : ""), "fail", 100);
			} else {
				hideProgress();
			}
		} else if (!r.current_version && !r.binary) {
			showProgress(I18N.missing, "idle", 0);
		} else {
			hideProgress();
		}
		return state;
	}

	function active(state) {
		return state === "starting" || state === "downloading" || state === "verifying";
	}

	function pollCore() {
		var out = document.getElementById("cf-core-out");

		if (pollTimer) {
			clearTimeout(pollTimer);
			pollTimer = null;
		}
		cfAction("core_status", {}).then(function(r) {
			if (active(applyStatus(r))) {
				pollCount++;
				if (pollCount > 600) {   /* about 12 minutes */
					tracking = false;
					if (out) out.textContent = I18N.timeout;
					showProgress(I18N.timeout, "fail", 100);
					return;
				}
				pollTimer = setTimeout(pollCore, 1200);
			}
		});
	}

	window.cfCoreStatus = function() {
		var out = document.getElementById("cf-core-out");
		tracking = true;
		if (out) out.textContent = I18N.check + "...";
		cfAction("core_status", {}).then(function(r) {
			if (out) {
				out.textContent = "[" + (r.state || "") + "] " + (r.message || "") +
					(r.current_version ? ("\n" + I18N.current + ": " + r.current_version) : "");
			}
			applyStatus(r);
			if (active(r.state)) {
				setTimeout(window.cfCoreStatus, 1500);
			}
		});
	};

	window.cfCoreInstall = function() {
		var out = document.getElementById("cf-core-out");

		if (pollTimer) {
			clearTimeout(pollTimer);
			pollTimer = null;
		}
		tracking = true;
		pollCount = 0;
		if (out) out.textContent = I18N.checking;
		showProgress(I18N.checking, "indeterminate", 0);

		cfAction("core_check", {}).then(function(c) {
			if (c.ok && c.up_to_date) {
				tracking = false;
				if (out) out.textContent = I18N.uptodate + " (" + (c.current || "") + ")";
				showProgress(I18N.uptodate, "done", 100);
				setTimeout(hideProgress, 5000);
				return;
			}

			if (out) out.textContent = I18N.starting;
			showProgress(I18N.starting, "indeterminate", 0);
			cfAction("core_install", {}).then(function(r) {
				if (!r.ok) {
					tracking = false;
					if (out) out.textContent = r.message || I18N.failed;
					showProgress(I18N.failed + (r.message ? (": " + r.message) : ""), "fail", 100);
					return;
				}
				pollCore();
			});
		});
	};

	window.cfUploadCore = function(file) {
		var out = document.getElementById("cf-core-out");
		var form = new FormData();
		var xhr = new XMLHttpRequest();

		if (pollTimer) {
			clearTimeout(pollTimer);
			pollTimer = null;
		}
		pollCount = 0;

		form.append("action", "core_upload");
		form.append("token", window.cfToken ? window.cfToken() : "");
		form.append("file", file);

		tracking = true;
		if (out) out.textContent = I18N.uploading;
		showProgress(I18N.uploading, "indeterminate", 0);

		xhr.open("POST", window.cfActionUrl ? window.cfActionUrl() : "");

		xhr.upload.onprogress = function(ev) {
			if (ev.lengthComputable && ev.total > 0) {
				var pct = Math.max(1, Math.floor(ev.loaded / ev.total * 100));
				showProgress(I18N.uploading + " " + pct + "%", "progress", pct);
			}
		};

		xhr.onerror = function() {
			tracking = false;
			if (out) out.textContent = I18N.upload_failed;
			showProgress(I18N.upload_failed, "fail", 100);
		};

		xhr.onload = function() {
			var r;
			try {
				r = JSON.parse(xhr.responseText);
			} catch (e) {
				r = { ok: false, message: I18N.upload_failed };
			}

			if (!r.ok) {
				tracking = false;
				if (out) out.textContent = r.message || I18N.upload_failed;
				showProgress(I18N.upload_failed + (r.message ? (": " + r.message) : ""), "fail", 100);
				return;
			}

			tracking = false;
			showProgress(I18N.upload_done, "done", 100);
			if (out) out.textContent = I18N.current + ": " + (r.version || "—");
			setTimeout(function() { location.reload(); }, 1500);
		};

		xhr.send(form);
	};

	var fileInput = document.getElementById("cf-core-file");
	if (fileInput) {
		fileInput.addEventListener("change", function(ev) {
			var f = ev.target.files && ev.target.files[0];
			if (f) window.cfUploadCore(f);
			ev.target.value = "";
		});
	}

	var enableCb = document.getElementById("cf-service-enabled");
	if (enableCb) {
		enableCb.addEventListener("change", function() {
			var want = enableCb.checked ? 1 : 0;
			enableCb.disabled = true;
			cfAction("service_enable", { enabled: want }).then(function(r) {
				enableCb.disabled = false;
				if (!r.ok) {
					enableCb.checked = !enableCb.checked;
					alert(r.message || I18N.service_failed);
				} else {
					enableCb.checked = !!r.enabled;
				}
			});
		});
	}

	cfAction("core_status", {}).then(function(r) {
		if (active(applyStatus(r))) pollCore();
	});
})();
</script>
]]

	return table.concat(html)
end


-- ===== Main Settings =====

s = m:section(TypedSection, "main", translate("Main Settings"))
s.anonymous = true
s.addremove = false

local o_base = s:option(Value, "base_path", translate("Cloudflare Base Path"),
	translate("Directory for tunnel data, cert.pem and downloaded binary."))
o_base.default = "/opt/cloudflare"

local o_bin = s:option(Value, "cloudflared_path", translate("Cloudflared Binary Path"),
	translate("Leave empty to auto-detect from base path."))
o_bin.placeholder = bin or translate("Not found")
o_bin.rmempty = true

local o_cert = s:option(Value, "cert_path", translate("Default Certificate Path"),
	translate("Leave empty to use <base_path>/cert.pem."))
o_cert.placeholder = base .. "/cert.pem"
o_cert.rmempty = true

local o_token = s:option(Value, "api_token", translate("Cloudflare API Token"))
o_token.password = true

local o_dl = s:option(Value, "download_url", translate("Download URL"),
	translate("Base URL for cloudflared releases. Useful for mirrors."))
o_dl.default = "https://github.com/cloudflare/cloudflared/releases/latest/download"
o_dl.rmempty = true

local o_del = s:option(Flag, "allow_dns_delete", translate("Allow DNS Deletion"),
	translate("Disabled by default. Only delete records matching the current tunnel target when enabled."))
o_del.default = "0"
o_del.rmempty = false


-- ===== Hooks =====

function m.on_after_commit(self)
	self.uci:commit("cloudflared")

	if main_restart_signature(self.uci) ~= main_before then
		common.regen_sections(common.tunnel_sections())
		common.restart_service()
	end
end

return m
