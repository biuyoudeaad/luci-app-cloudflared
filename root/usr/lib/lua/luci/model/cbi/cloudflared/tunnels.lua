local uci = require "luci.model.uci".cursor()
local common = require "luci.cloudflared.common"

m = Map("cloudflared",
	translate("Cloudflared Tunnels"),
	translate("Each tunnel has its own domain, credentials and config.yml."))

m.apply_on_parse = false

local snap_before = common.snapshot_tunnels()


-- ===== Shared tunnel actions =====

local jssec = m:section(SimpleSection)
jssec.anonymous = true
local jso = jssec:option(DummyValue, "_js")
jso.rawhtml = true
jso.cfgvalue = function()
	return common.js_helpers() .. [[
<style>.cf-tunnel-script-host{display:none!important}</style>
<script>
(function(){var s=document.currentScript;var h=s&&s.closest(".cbi-section");if(h)h.classList.add("cf-tunnel-script-host")})();
function cfFieldValue(id) {
	var el = document.getElementById(id);
	if (!el) return "";
	var node = (el.matches && el.matches("input, select, textarea")) ? el :
		(el.querySelector ? el.querySelector("input, select, textarea") : null);
	if (!node) return "";
	if (node.type === "checkbox") return node.checked ? "1" : "0";
	return node.value || "";
}
function cfHotReload(sec) {
	var domain = cfFieldValue("cbid.cloudflared." + sec + ".domain").replace(/^\s+|\s+$/g, "");
	var box = document.getElementById("cf-login-" + sec);

	if (!domain) {
		if (box) box.textContent = "]] .. translate("Please enter a domain first") .. [[";
		return;
	}

	if (box) box.textContent = "]] .. translate("Hot reloading") .. [[ " + domain + "...";
	var rewrite = document.getElementById("cf-opt-rewrite-" + sec);
	var dns = document.getElementById("cf-opt-dns-" + sec);
	var restart = document.getElementById("cf-opt-restart-" + sec);
	cfAction("domain_switch", {
		section: sec,
		new_domain: domain,
		rewrite_hosts: (!rewrite || rewrite.checked) ? "1" : "0",
		sync_dns: (!dns || dns.checked) ? "1" : "0",
		restart: (!restart || restart.checked) ? "1" : "0"
	}).then(function(r) {
		if (box) box.textContent = r.message || (r.ok ? "OK" : "Failed");
		if (r.ok) location.reload();
	});
}
function cfSyncDns(sec) {
	cfAction("dns_sync", { section: sec }).then(function(r) {
		alert(r.message || (r.ok ? "OK" : "Failed"));
	});
}
function cfCreateTunnel(sec) {
	var name = cfFieldValue("cbid.cloudflared." + sec + ".name").replace(/^\s+|\s+$/g, "");
	if (!name) name = "tunnel-" + Math.floor(Date.now() / 1000);
	var box = document.getElementById("cf-login-" + sec);
	if (box) box.textContent = "]] .. translate("Creating...") .. [[";
	cfAction("tunnel_create", { section: sec, name: name }).then(function(r) {
		if (box) box.textContent = r.message || (r.ok ? "OK" : "Failed");
		if (r.ok) location.reload();
	});
}
function cfLoginStart(sec) {
	cfAction("login_start", { section: sec, force: "1" }).then(function(r) {
		if (!r.ok) { alert(r.message || "Failed"); return; }
		cfLoginPoll(sec);
	});
}
function cfEscape(s) {
	return String(s == null ? "" : s)
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;")
		.replace(/'/g, "&#39;");
}
function cfLoginPoll(sec) {
	var box = document.getElementById("cf-login-" + sec);
	cfAction("login_status", { section: sec }).then(function(r) {
		if (box) {
			var html = cfEscape(r.state || "") + "<br>" + cfEscape(r.message || "");
			if (r.url) {
				var safeUrl = cfEscape(r.url);
				html += '<br><a target="_blank" rel="noopener" href="' + safeUrl + '">' + safeUrl + "</a> ";
				html += '<button type="button" class="btn cbi-button" onclick="cfCopyUrl(\'' + sec + '\')">]] .. translate("Copy URL") .. [[</button>';
				html += '<input type="hidden" id="cf-login-url-' + sec + '" value="' + safeUrl + '">';
			}
			box.innerHTML = html;
		}
		if (r.state === "waiting" || r.state === "starting") {
			setTimeout(function() { cfLoginPoll(sec); }, 3000);
		} else if (r.state === "done") {
			location.reload();
		}
	});
}
function cfCopyUrl(sec) {
	var input = document.getElementById("cf-login-url-" + sec);
	if (!input) return;
	if (navigator.clipboard && navigator.clipboard.writeText) {
		navigator.clipboard.writeText(input.value);
	} else {
		input.type = "text";
		input.select();
		document.execCommand("copy");
		input.type = "hidden";
	}
}
</script>
]]
end


-- ===== Tunnel settings =====

s = m:section(TypedSection, "tunnel", translate("Tunnels"))
s.anonymous = true
s.addremove = true

local name = s:option(Value, "name", translate("Name"))
name.placeholder = "office"

local enabled = s:option(Flag, "enabled", translate("Enabled"))
enabled.default = "1"
enabled.rmempty = false

local domain = s:option(Value, "domain", translate("Domain"),
	translate("Root domain of this tunnel, e.g. example.com."))
domain.placeholder = "example.com"
domain.datatype = "hostname"

local tid = s:option(Value, "tunnel_id", translate("Tunnel ID"),
	translate("Cloudflare tunnel UUID. Must be unique."))
tid.placeholder = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

tid.validate = function(self, value, section)
	local dup = false
	self.map.uci:foreach("cloudflared", "tunnel", function(sec)
		if sec[".name"] ~= section and sec.tunnel_id == value and value ~= "" then
			dup = true
		end
	end)
	if dup then
		return nil, translate("Tunnel ID already used by another tunnel")
	end
	return value
end

local datadir = s:option(Value, "data_dir", translate("Data Directory"),
	translate("Leave empty to use <base_path>/tunnels/<section>."))
datadir.rmempty = true

local certpath = s:option(Value, "cert_path", translate("Certificate Path"),
	translate("Leave empty to use the default cert.pem."))
certpath.rmempty = true

local credfile = s:option(Value, "credentials_file", translate("Credentials File"),
	translate("Leave empty to auto-detect <tunnel_id>.json in the data directory."))
credfile.rmempty = true

local ttoken = s:option(Value, "api_token", translate("API Token Override"),
	translate("Optional. Required only when this tunnel belongs to another Cloudflare account."))
ttoken.password = true
ttoken.rmempty = true

local applied = s:option(DummyValue, "_applied", translate("Domain Status"))
applied.rawhtml = true
applied.cfgvalue = function(self, section)
	local d = uci:get("cloudflared", section, "domain") or ""
	local a = uci:get("cloudflared", section, "applied_domain") or d
	if d == "" then
		return "<span style='color:#aaa'>—</span>"
	end
	if d == a then
		return "<span style='color:#27ae60;font-weight:bold'>● " .. translate("Applied") .. "</span> (" .. a .. ")"
	end
	return "<span style='color:#e67e22;font-weight:bold'>● " ..
		translate("Pending hot reload") .. "</span> (" .. a .. " → " .. d .. ")"
end

local actions = s:option(DummyValue, "_actions", translate("Actions"))
actions.rawhtml = true
actions.cfgvalue = function(self, section)
	local html = {}
	local arrow = ' <span style="color:#999;margin:0 4px">&rarr;</span> '

	html[#html + 1] = '<button type="button" class="btn cbi-button" onclick="cfLoginStart(\'' .. section .. '\')">' .. translate("Authorize") .. "</button>"
	html[#html + 1] = arrow
	html[#html + 1] = '<button type="button" class="btn cbi-button cbi-button-action" onclick="cfCreateTunnel(\'' .. section .. '\')">' .. translate("Create Tunnel") .. "</button>"
	html[#html + 1] = arrow
	html[#html + 1] = '<button type="button" class="btn cbi-button" onclick="cfSyncDns(\'' .. section .. '\')">' .. translate("Sync DNS") .. "</button>"
	html[#html + 1] = arrow
	html[#html + 1] = '<button type="button" class="btn cbi-button cbi-button-apply" onclick="cfHotReload(\'' .. section .. '\')">' .. translate("Hot Reload") .. "</button>"
	html[#html + 1] = '<div style="margin-top:6px;font-size:90%">'
	html[#html + 1] = '<label><input type="checkbox" id="cf-opt-rewrite-' .. section .. '" checked> ' .. translate("Rewrite hostnames") .. "</label> "
	html[#html + 1] = '<label><input type="checkbox" id="cf-opt-dns-' .. section .. '" checked> ' .. translate("Sync DNS") .. "</label> "
	html[#html + 1] = '<label><input type="checkbox" id="cf-opt-restart-' .. section .. '" checked> ' .. translate("Restart") .. "</label>"
	html[#html + 1] = "</div>"
	html[#html + 1] = '<div id="cf-login-' .. section .. '" style="margin-top:6px;font-size:90%"></div>'
	return table.concat(html)
end


-- ===== Certificate / credentials upload =====

local up = m:section(TypedSection, "tunnel", translate("Certificate & Credentials"),
	translate("Upload cert.pem or tunnel credentials JSON, then click Save & Apply. Changes are applied automatically. If the browser cannot reach the router, download cert.pem from Cloudflare and upload it here."))
up.anonymous = true
up.addremove = false

local upname = up:option(DummyValue, "_upname", translate("Tunnel"))
upname.rawhtml = true
upname.cfgvalue = function(self, section)
	local n = uci:get("cloudflared", section, "name") or section
	local d = uci:get("cloudflared", section, "domain") or ""
	return "<strong>" .. n .. "</strong>" .. (d ~= "" and (" (" .. d .. ")") or "")
end

local upcert = up:option(FileUpload, "_cert_upload", translate("Upload cert.pem"))
upcert.rmempty = true
upcert.write = function(self, section, value)
	return true
end
upcert.remove = function() return true end

local upcred = up:option(FileUpload, "_cred_upload", translate("Upload credentials.json"))
upcred.rmempty = true
upcred.write = function(self, section, value)
	return true
end
upcred.remove = function() return true end


-- ===== Hooks =====

function m.on_after_commit(self)
	self.uci:commit("cloudflared")

	local snap_after = common.snapshot_tunnels()
	local changed, added, removed = common.diff_snapshots(snap_before, snap_after)
	local regen = {}
	local force_restart = (#added > 0) or (#removed > 0)

	for _, section in ipairs(changed) do
		regen[section] = true
	end

	self.uci:foreach("cloudflared", "tunnel", function(sec)
		local section = sec[".name"]
		local cert = upcert:formvalue(section)
		local cred = upcred:formvalue(section)

		if cert and cert ~= "" then
			common.action_upload("cert", section, cert)
			regen[section] = true
			force_restart = true
		end
		if cred and cred ~= "" then
			common.action_upload("credentials", section, cred)
			regen[section] = true
			force_restart = true
		end

		local d = sec.domain or ""
		local a = sec.applied_domain or d
		if d ~= "" and d ~= a then
			common.action_domain_switch({
				section = section,
				new_domain = d,
				restart = "0",
			})
			regen[section] = true
			force_restart = true
		end
	end)

	local sections = {}
	for section in pairs(regen) do
		sections[#sections + 1] = section
	end
	table.sort(sections)

	local ok, cfg_changed = common.regen_sections(sections)
	if cfg_changed or force_restart then
		common.restart_service()
	end
end

return m
