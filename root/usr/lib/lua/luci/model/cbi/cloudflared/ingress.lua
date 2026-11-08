local uci = require "luci.model.uci".cursor()
local common = require "luci.cloudflared.common"
local xml = require "luci.xml"

m = Map("cloudflared",
	translate("Ingress Rules"),
	translate("Map public hostnames to local services."))

m.apply_on_parse = false

local snap_before = common.snapshot_tunnels()


-- ===== Load tunnels and DNS state =====

local tunnels = {}
local tunnel_by_section = {}

uci:foreach("cloudflared", "tunnel", function(sec)
	local token = sec.api_token or ""
	if token == "" then
		token = uci:get("cloudflared", "main", "api_token") or ""
	end
	local t = {
		section = sec[".name"],
		name = sec.name or sec[".name"],
		enabled = sec.enabled ~= "0",
		domain = sec.domain or "",
		tunnel_id = sec.tunnel_id or "",
		token = token,
	}
	tunnels[#tunnels + 1] = t
	tunnel_by_section[t.section] = t
end)

local dns_ready = {}

for _, t in ipairs(tunnels) do
	if t.token ~= "" and t.domain ~= "" and t.tunnel_id ~= "" then
		dns_ready[t.section] = true
	end
end

local ing_desc = translate("Save & Apply regenerates config.yml, syncs missing DNS CNAME records and restarts the service.") ..
	"<br>" .. translate("The Test button checks the saved backend target, tunnel status and DNS record.") ..
	'<div id="cf-orphan-warning"></div>'


-- ===== Shared helpers =====

local jssec = m:section(SimpleSection)
jssec.anonymous = true
local jso = jssec:option(DummyValue, "_js")
jso.rawhtml = true
jso.cfgvalue = function()
	return common.js_helpers() .. [[
<script>
function cfTestIngress(sec) {
	var box = document.getElementById("cf-test-" + sec);
	if (box) {
		box.textContent = "...";
		box.title = "";
	}
	cfAction("test_ingress", { section: sec }).then(function(r) {
		if (!box) return;
		var parts = [];
		if (r.backend) parts.push(r.backend);
		if (r.tunnel_running === false) parts.push("]] .. translate("Tunnel not running") .. [[");
		if (r.dns) parts.push("DNS: " + r.dns);
		if (r.public_status) parts.push("]] .. translate("Public") .. [[: " + r.public_status);
		box.textContent = (r.ok ? "✔ " : "✖ ") + parts.join(" | ");
		box.title = JSON.stringify(r, null, 2);
	});
}
</script>
<style>
#cf-ingress-modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:10000}
#cf-ingress-modal .cf-modal-box{background:#fff;color:#222;max-width:760px;margin:4% auto;border-radius:8px;padding:18px 20px;max-height:86vh;overflow:auto;box-shadow:0 8px 30px rgba(0,0,0,.35)}
#cf-ingress-modal h3{margin:0 0 14px;font-size:1.1em}
.cf-setting-row{display:flex;gap:12px;align-items:flex-start;margin-bottom:10px}
.cf-setting-row > label{flex:0 0 190px;font-weight:600;padding-top:6px}
.cf-protocol-confirm{margin:-4px 0 12px 202px}
.cbi-tblsection table th:nth-child(n+6):nth-child(-n+25),
.cbi-tblsection table td:nth-child(n+6):nth-child(-n+25){display:none}
.cf-setting-field{flex:1 1 auto;min-width:0}
.cf-setting-field input[type=text],.cf-setting-field input[type=password],.cf-setting-field select{width:100%;box-sizing:border-box}
.cf-setting-desc{color:#777;font-size:.85em;margin-top:3px}
.cf-modal-actions{text-align:right;margin-top:16px;display:flex;gap:8px;justify-content:flex-end}
@media (max-width:600px){.cf-setting-row{display:block}.cf-setting-row > label{display:block;margin-bottom:4px}.cf-protocol-confirm{margin-left:0}}
</style>
<div id="cf-ingress-modal">
	<div class="cf-modal-box">
		<h3 id="cf-ingress-modal-title">]] .. translate("Settings") .. [[</h3>
		<div id="cf-ingress-modal-body"></div>
		<div class="cf-modal-actions">
			<button type="button" class="btn cbi-button" onclick="cfIngressCancel()">]] .. translate("Cancel") .. [[</button>
			<button type="button" class="btn cbi-button cbi-button-apply" onclick="cfIngressApply()">]] .. translate("Save & Apply") .. [[</button>
		</div>
	</div>
</div>
<script>
(function() {
	var modalFields = [
		"tunnel", "hostname",
		"_protocol", "_ip", "_port", "_path", "_status",
		"origin_host_header", "no_tls_verify", "origin_server_name",
		"ingress_path",
		"origin_connect_timeout", "origin_tls_timeout", "origin_tcp_keepalive",
		"origin_no_happy_eyeballs", "origin_proxy_address", "origin_proxy_port",
		"origin_proxy_type", "origin_http2", "origin_disable_chunked",
		"origin_keepalive_connections", "origin_keepalive_timeout",
		"origin_ca_pool", "origin_bastion_mode"
	];
	var modalOnly = [
		"ingress_path",
		"origin_connect_timeout", "origin_tls_timeout", "origin_tcp_keepalive",
		"origin_no_happy_eyeballs", "origin_proxy_address", "origin_proxy_port",
		"origin_proxy_type", "origin_http2", "origin_disable_chunked",
		"origin_keepalive_connections", "origin_keepalive_timeout",
		"origin_ca_pool", "origin_bastion_mode"
	];
	var columnDefs = [
		["tunnel", true],
		["hostname", true],
		["_protocol", true],
		["_ip", true],
		["_port", true],
		["_path", false],
		["_status", false],
		["origin_host_header", false],
		["no_tls_verify", false],
		["origin_server_name", false],
		["_service_summary", false],
		["_dns_status", true],
		["_test", true]
	];
	var STORAGE_KEY = "cf-ingress-columns-v4";
	var I18N = {
		synced: "]] .. translate("Synced") .. [[",
		pending: "]] .. translate("Pending") .. [[",
		unknown: "]] .. translate("Unknown") .. [[",
		cname: "]] .. translate("CNAME record exists") .. [[",
		willcreate: "]] .. translate("Will be created on next save") .. [[",
		noconfig: "]] .. translate("Cannot check: missing config") .. [[",
		orphan: "]] .. translate("Orphaned DNS (will be deleted on save)") .. [[",
		orphan_confirm: "]] .. translate("There are orphaned DNS records that will be deleted. Continue?") .. [["
	};
	var modal = document.getElementById("cf-ingress-modal");
	var body = document.getElementById("cf-ingress-modal-body");
	var state = null;

	function opt(sec, name) {
		return document.getElementById("cbid.cloudflared." + sec + "." + name);
	}

	function valueEl(el) {
		if (!el) return null;
		if (el.matches && el.matches("input, select, textarea"))
			return el;
		return el.querySelector ? el.querySelector("input, select, textarea") : null;
	}

	function fieldValue(sec, name) {
		var el = valueEl(opt(sec, name));
		if (!el) return "";
		if (el.type === "checkbox") return el.checked ? "1" : "0";
		return el.value || "";
	}

	function protocolValue(sec) {
		var v = fieldValue(sec, "_protocol");
		return v ? String(v).toLowerCase() : "http";
	}

	function serviceValue(sec) {
		var p = protocolValue(sec);
		if (p === "unix") return "unix:" + fieldValue(sec, "_path");
		if (p === "http_status") return "http_status:" + fieldValue(sec, "_status");
		var port = fieldValue(sec, "_port");
		return p + "://" + fieldValue(sec, "_ip") + (port ? ":" + port : "");
	}

	function updateSummary(sec) {
		var el = document.getElementById("cf-service-" + sec);
		if (!el) return;
		el.textContent = "";
		var code = document.createElement("code");
		code.textContent = serviceValue(sec);
		el.appendChild(code);
	}

	function updateVisibility() {
		if (!state) return;
		var p = protocolValue(state.sec);
		var isHttp = (p === "http" || p === "https" || p === "unix");
		var isTls = (p === "https");
		var isTcp = (p !== "unix" && p !== "http_status");
		var map = {
			"_ip": isTcp,
			"_port": isTcp,
			"_path": (p === "unix"),
			"_status": (p === "http_status"),
			"origin_host_header": isHttp,
			"no_tls_verify": isTls,
			"origin_server_name": isTls,
			"ingress_path": isHttp,
			"origin_connect_timeout": (p !== "http_status"),
			"origin_tls_timeout": isTls,
			"origin_tcp_keepalive": isTcp,
			"origin_no_happy_eyeballs": isTcp,
			"origin_proxy_address": isTcp,
			"origin_proxy_port": isTcp,
			"origin_proxy_type": isTcp,
			"origin_http2": isHttp,
			"origin_disable_chunked": isHttp,
			"origin_keepalive_connections": isHttp,
			"origin_keepalive_timeout": isHttp,
			"origin_ca_pool": isTls,
			"origin_bastion_mode": (p === "ssh")
		};
		state.items.forEach(function(it) {
			it.wrap.style.display = (map[it.name] === false) ? "none" : "";
		});
	}

	function showProtocolConfirm() {
		if (!state || !state.protocolConfirm) return;
		state.protocolPending = true;
		state.protocolConfirm.style.display = "block";
	}

	function openSettings(row, sec) {
		body.innerHTML = "";
		state = { row: row, sec: sec, items: [], originals: [] };

		modalFields.forEach(function(name) {
			var el = opt(sec, name);
			if (!el) return;
			var td = el.closest("td");
			if (!td) return;

			var title = name;
			var table = row.closest("table");
			if (table && table.rows.length) {
				var th = table.rows[0].cells[td.cellIndex];
				if (th) title = th.textContent.replace(/^\s+|\s+$/g, "");
			}

			var wrap = document.createElement("div");
			wrap.className = "cf-setting-row";
			var lab = document.createElement("label");
			lab.textContent = title;
			var field = document.createElement("div");
			field.className = "cf-setting-field";
			while (td.firstChild) field.appendChild(td.firstChild);
			wrap.appendChild(lab);
			wrap.appendChild(field);
			body.appendChild(wrap);

			state.items.push({ name: name, td: td, wrap: wrap, field: field });
			var ve = valueEl(el);
			if (ve) {
				state.originals.push({ el: ve, value: ve.value, checked: ve.checked });
			}
			if (!el._cfIngressBound) {
				el._cfIngressBound = true;
				var handler = function() {
					if (name === "_protocol") {
						showProtocolConfirm();
						updateVisibility();
					}
					updateSummary(sec);
				};
				[el, ve].forEach(function(node) {
					if (!node) return;
					node.addEventListener("input", handler);
					node.addEventListener("change", handler);
					node.addEventListener("widget-change", handler);
					node.addEventListener("cbi-dropdown-change", handler);
				});
			}
		});

		state.protocolPending = false;
		var protoItem = null;
		state.items.forEach(function(it) {
			if (it.name === "_protocol") protoItem = it;
		});
		if (protoItem) {
			var confirmWrap = document.createElement("div");
			confirmWrap.className = "cf-protocol-confirm";
			confirmWrap.style.display = "none";
			var confirmBtn = document.createElement("button");
			confirmBtn.type = "button";
			confirmBtn.className = "btn cbi-button cbi-button-apply";
			confirmBtn.textContent = "]] .. translate("Confirm Protocol Change") .. [[";
			confirmBtn.addEventListener("click", function() {
				if (!state) return;
				state.protocolPending = false;
				confirmWrap.style.display = "none";
				updateVisibility();
			});
			confirmWrap.appendChild(confirmBtn);
			protoItem.wrap.parentNode.insertBefore(confirmWrap, protoItem.wrap.nextSibling);
			state.protocolConfirm = confirmWrap;
		}

		updateVisibility();
		modal.style.display = "block";
	}

	function closeSettings() {
		if (!state) return;
		state.items.forEach(function(it) {
			while (it.field.firstChild) it.td.appendChild(it.field.firstChild);
		});
		var sec = state.sec;
		modal.style.display = "none";
		updateSummary(sec);
		state = null;
	}

	window.cfIngressCancel = function() {
		if (!state) return;
		state.originals.forEach(function(o) {
			if (o.el.type === "checkbox") o.el.checked = o.checked;
			else o.el.value = o.value;
		});
		closeSettings();
	};

	window.cfIngressApply = function() {
		var row = state ? state.row : null;
		if (state && state.protocolPending)
			updateVisibility();
		closeSettings();
		if (row) {
			var form = row.closest("form");
			var apply = form && (form.querySelector(".cbi-page-actions input.cbi-button-apply") ||
				form.querySelector('input.cbi-button-apply[onclick*="cbi.apply"]'));
			if (apply) apply.click();
		}
	};

	function savedColumns() {
		try {
			var saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
			if (saved && typeof saved === "object") return saved;
			return {};
		} catch (e) {
			return {};
		}
	}

	function isColumnVisible(key, dflt) {
		var saved = savedColumns();
		return saved.hasOwnProperty(key) ? !!saved[key] : dflt;
	}

	function setColumnVisible(key, visible) {
		var saved = savedColumns();
		saved[key] = !!visible;
		try {
			localStorage.setItem(STORAGE_KEY, JSON.stringify(saved));
		} catch (e) {}
		var firstRow = document.querySelector("tr.cbi-section-table-row[id^='cbi-cloudflared-']");
		if (firstRow) applyColumns(firstRow);
	}

	function cellForColumn(row, key) {
		var sec = row.id.substring("cbi-cloudflared-".length);
		var el;
		if (key === "_service_summary")
			el = document.getElementById("cf-service-" + sec);
		else if (key === "_dns_status")
			el = document.getElementById("cf-dns-" + sec);
		else if (key === "_test")
			el = document.getElementById("cf-test-" + sec);
		else
			el = opt(sec, key);
		return el ? el.closest("td") : null;
	}

	function applyColumns(firstRow) {
		var table = firstRow ? firstRow.closest("table") : null;
		if (!table) return;

		columnDefs.forEach(function(def) {
			var key = def[0], dflt = def[1];
			var cell = cellForColumn(firstRow, key);
			if (!cell) return;
			var idx = cell.cellIndex;
			var vis = isColumnVisible(key, dflt);
			for (var r = 0; r < table.rows.length; r++) {
				var c = table.rows[r].cells[idx];
				if (c) c.style.display = vis ? "table-cell" : "none";
			}
		});
	}

	function buildColumnMenu(firstRow) {
		var table = firstRow.closest("table");
		if (!table) return;
		if (table.previousElementSibling &&
		    table.previousElementSibling.classList.contains("cf-columns-toolbar"))
			return;

		var titleRow = table.rows[0];
		var toolbar = document.createElement("div");
		toolbar.className = "cf-columns-toolbar";
		toolbar.style.cssText = "display:flex;justify-content:flex-end;margin:4px 0 6px;position:relative";

		var btn = document.createElement("button");
		btn.type = "button";
		btn.className = "btn cbi-button";
		btn.textContent = "]] .. translate("Columns") .. [[";

		var menu = document.createElement("div");
		menu.style.cssText = "display:none;position:absolute;right:0;top:100%;z-index:600;background:#fff;color:#222;border:1px solid #ccc;border-radius:6px;padding:8px 10px;min-width:240px;max-height:60vh;overflow:auto;box-shadow:0 4px 16px rgba(0,0,0,.2);text-align:left";

		columnDefs.forEach(function(def) {
			var key = def[0], dflt = def[1];
			var cell = cellForColumn(firstRow, key);
			if (!cell) return;
			var th = titleRow && titleRow.cells[cell.cellIndex];
			var label = th ? th.textContent.replace(/^\s+|\s+$/g, "") : key;

			var row = document.createElement("label");
			row.style.cssText = "display:flex;align-items:center;gap:8px;padding:5px 0;font-weight:normal;cursor:pointer";
			var cb = document.createElement("input");
			cb.type = "checkbox";
			cb.checked = isColumnVisible(key, dflt);
			cb.addEventListener("change", function() { setColumnVisible(key, cb.checked); });
			var span = document.createElement("span");
			span.textContent = label;
			row.appendChild(cb);
			row.appendChild(span);
			menu.appendChild(row);
		});

		var reset = document.createElement("button");
		reset.type = "button";
		reset.className = "btn cbi-button";
		reset.textContent = "]] .. translate("Reset") .. [[";
		reset.style.cssText = "margin-top:8px;width:100%;border-top:1px solid #ddd";
		reset.addEventListener("click", function() {
			try { localStorage.removeItem(STORAGE_KEY); } catch (e) {}
			try { localStorage.removeItem("cf-ingress-columns-v2"); } catch (e) {}
			try { localStorage.removeItem("cf-ingress-columns-v3"); } catch (e) {}
			location.reload();
		});
		menu.appendChild(reset);

		btn.addEventListener("click", function(ev) {
			ev.stopPropagation();
			menu.style.display = (menu.style.display === "none" || menu.style.display === "") ? "block" : "none";
		});
		menu.addEventListener("click", function(ev) { ev.stopPropagation(); });
		document.addEventListener("click", function() { menu.style.display = "none"; });

		toolbar.appendChild(btn);
		toolbar.appendChild(menu);
		table.parentNode.insertBefore(toolbar, table);
	}

	function loadDns() {
		cfAction("ingress_dns", {}).then(function(r) {
			if (!r || !r.ok) {
				document.querySelectorAll("[id^='cf-dns-']").forEach(function(box) {
					box.innerHTML = '<span style="color:#aaa" title="' + I18N.noconfig + '">● ' + I18N.unknown + '</span>';
				});
				return;
			}

			Object.keys(r.status || {}).forEach(function(sec) {
				var box = document.getElementById("cf-dns-" + sec);
				if (!box) return;
				var st = r.status[sec];
				if (st === "synced")
					box.innerHTML = '<span style="color:#27ae60;font-weight:bold" title="' + I18N.cname + '">● ' + I18N.synced + '</span>';
				else if (st === "pending")
					box.innerHTML = '<span style="color:#e67e22;font-weight:bold" title="' + I18N.willcreate + '">● ' + I18N.pending + '</span>';
				else if (st === "unknown")
					box.innerHTML = '<span style="color:#aaa" title="' + I18N.noconfig + '">● ' + I18N.unknown + '</span>';
				else
					box.innerHTML = '<span style="color:#ccc">—</span>';
			});

			var warn = document.getElementById("cf-orphan-warning");
			if (warn) {
				if (r.allow_delete && r.orphaned && r.orphaned.length) {
					var notice = document.createElement("span");
					notice.style.cssText = "color:#e67e22;font-weight:bold";
					notice.textContent = "⚠ " + I18N.orphan + ": " + r.orphaned.join(", ");
					warn.replaceChildren(document.createElement("br"), notice);
					var form = document.querySelector('form[name="cbi"]');
					if (form && !form.cfOrphanConfirm) {
						form.cfOrphanConfirm = true;
						form.addEventListener("submit", function(e) {
							if (!confirm(I18N.orphan_confirm)) {
								e.preventDefault();
								e.stopPropagation();
								return false;
							}
						});
					}
				} else {
					warn.innerHTML = "";
				}
			}
		}).catch(function() {
			document.querySelectorAll("[id^='cf-dns-']").forEach(function(box) {
				box.innerHTML = '<span style="color:#aaa" title="' + I18N.noconfig + '">● ' + I18N.unknown + '</span>';
			});
		});
	}

	function setup() {
		var firstRow = document.querySelector("tr.cbi-section-table-row[id^='cbi-cloudflared-']");
		if (!firstRow) {
			loadDns();
			return;
		}

		document.querySelectorAll("tr.cbi-section-table-row[id^='cbi-cloudflared-']").forEach(function(row) {
			var sec = row.id.substring("cbi-cloudflared-".length);
			var actions = row.querySelector("td.cbi-section-actions > div");
			if (actions && !actions.querySelector(".cf-settings-btn")) {
				var btn = document.createElement("button");
				btn.type = "button";
				btn.className = "btn cbi-button cf-settings-btn";
				btn.textContent = "]] .. translate("Settings") .. [[";
				btn.addEventListener("click", function() { openSettings(row, sec); });
				actions.insertBefore(btn, actions.firstChild);
			}
			modalOnly.forEach(function(name) {
				var el = opt(sec, name);
				if (!el) return;
				var td = el.closest("td");
				if (!td) return;
				td.style.display = "none";
				var table = row.closest("table");
				if (table && table.rows.length) {
					var idx = td.cellIndex;
					if (table.rows[0].cells[idx]) table.rows[0].cells[idx].style.display = "none";
					var dr = table.querySelector("tr.cbi-section-table-descr");
					if (dr && dr.cells[idx]) dr.cells[idx].style.display = "none";
				}
			});
		});

		buildColumnMenu(firstRow);
		applyColumns(firstRow);
		loadDns();
	}

	function refreshColumns() {
		var firstRow = document.querySelector("tr.cbi-section-table-row[id^='cbi-cloudflared-']");
		if (firstRow) applyColumns(firstRow);
	}

	if (document.readyState === "loading")
		document.addEventListener("DOMContentLoaded", setup);
	else
		setup();
	window.addEventListener("pageshow", refreshColumns);
	window.addEventListener("load", refreshColumns);
	window.setTimeout(refreshColumns, 0);
})();
</script>
]]
end


-- ===== Ingress rules =====

ing = m:section(TypedSection, "ingress", translate("Ingress Rules"), ing_desc)
ing.template = "cbi/tblsection"
ing.anonymous = true
ing.addremove = true

local tunnel_opt = ing:option(ListValue, "tunnel", translate("Tunnel"))
for _, t in ipairs(tunnels) do
	tunnel_opt:value(t.section, t.name .. (t.domain ~= "" and (" (" .. t.domain .. ")") or ""))
end

-- Heal legacy rows that were saved without a tunnel reference (or with one
-- that no longer exists). With a single tunnel the choice is unambiguous.
tunnel_opt.cfgvalue = function(self, section)
	local v = uci:get("cloudflared", section, "tunnel")
	if v and tunnel_by_section[v] then
		return v
	end
	if #tunnels == 1 then
		return tunnels[1].section
	end
	return v
end

local hostname = ing:option(Value, "hostname", translate("Hostname"),
	translate("Full hostname, e.g. app.example.com."))
hostname.placeholder = "app.example.com"
hostname.datatype = "hostname"

hostname.write = function(self, section, value)
	if value and value ~= "" and not value:match("%.") then
		local ts = tunnel_opt:formvalue(section) or uci:get("cloudflared", section, "tunnel")
		local t = ts and tunnel_by_section[ts]
		if t and t.domain ~= "" then
			value = value .. "." .. t.domain
		end
	end
	Value.write(self, section, value)
end

local function parse_service(service)
	if not service or service == "" then
		return nil, nil, nil, nil
	end

	local scheme, rest = service:match("^([%w_]+):(.+)$")
	if not scheme then
		return nil, nil, nil, nil
	end
	if scheme == "unix" or scheme == "http_status" then
		return scheme, "", nil, rest
	end

	local host, port
	host, port = rest:match("^//%[([^%]]+)%]:(%d+)")
	if not host then
		host, port = rest:match("^//([^:/]+):(%d+)")
	end
	if not host then
		host = rest:match("^//([^:/]+)")
	end
	if not host then
		return nil, nil, nil, nil
	end
	return scheme, host, tonumber(port), rest
end

local proto
local ip
local port
local upath
local ucode

local function service_part_from_form(opt, section)
	if not opt then
		return nil
	end
	return opt:formvalue(section)
end

local function service_part_from_cfg(opt, section, fallback)
	if not opt then
		return fallback
	end
	local v = opt.cfgvalue and opt:cfgvalue(section) or nil
	if v == nil or v == "" then
		return fallback
	end
	return v
end

local function sync_service(section)
	local proto_val = service_part_from_form(proto, section)
	if proto_val == nil then
		proto_val = service_part_from_cfg(proto, section, "http")
	end

	local cursor = (proto and proto.map and proto.map.uci) or uci

	if proto_val == "unix" then
		local path_val = service_part_from_form(upath, section)
		if path_val == nil then
			path_val = service_part_from_cfg(upath, section, "")
		end
		if path_val ~= "" then
			cursor:set("cloudflared", section, "service", "unix:" .. path_val)
		else
			cursor:delete("cloudflared", section, "service")
		end
	elseif proto_val == "http_status" then
		local code_val = service_part_from_form(ucode, section)
		if code_val == nil then
			code_val = service_part_from_cfg(ucode, section, "")
		end
		if code_val ~= "" then
			cursor:set("cloudflared", section, "service", "http_status:" .. code_val)
		else
			cursor:delete("cloudflared", section, "service")
		end
	else
		local ip_val = service_part_from_form(ip, section)
		local port_val = service_part_from_form(port, section)
		if ip_val == nil then
			ip_val = service_part_from_cfg(ip, section, "")
		end
		if port_val == nil then
			port_val = service_part_from_cfg(port, section, "")
		end
		if ip_val ~= "" and port_val ~= "" then
			local host_val = ip_val
			if host_val:find(":") then
				host_val = "[" .. host_val .. "]"
			end
			cursor:set("cloudflared", section, "service",
				string.format("%s://%s:%s", proto_val, host_val, port_val))
		else
			cursor:delete("cloudflared", section, "service")
		end
	end
end

proto = ing:option(ListValue, "_protocol", translate("Protocol"))
proto:value("http", "HTTP")
proto:value("https", "HTTPS")
proto:value("tcp", "TCP")
proto:value("ssh", "SSH")
proto:value("rdp", "RDP")
proto:value("smb", "SMB")
proto:value("unix", translate("Unix Socket"))
proto:value("http_status", translate("HTTP Status"))
proto.default = "http"

proto.cfgvalue = function(self, section)
	local svc = uci:get("cloudflared", section, "service") or ""
	local p = parse_service(svc)
	return p or "http"
end

proto.write = function(self, section, value)
	sync_service(section)
end

ip = ing:option(Value, "_ip", translate("IP / Host"))
ip.placeholder = "192.168.1.1 or localhost"
ip.datatype = "host"

ip.cfgvalue = function(self, section)
	local svc = uci:get("cloudflared", section, "service") or ""
	local _, host = parse_service(svc)
	return host or ""
end

ip.write = function(self, section, value)
	sync_service(section)
end

port = ing:option(Value, "_port", translate("Port"))
port.placeholder = "8080"
port.datatype = "port"

port.cfgvalue = function(self, section)
	local svc = uci:get("cloudflared", section, "service") or ""
	local _, _, prt = parse_service(svc)
	return prt or ""
end

port.write = function(self, section, value)
	sync_service(section)
end

upath = ing:option(Value, "_path", translate("Unix Socket Path"))
upath.placeholder = "/var/run/service.sock"
upath.cfgvalue = function(self, section)
	local svc = uci:get("cloudflared", section, "service") or ""
	local s, _, _, x = parse_service(svc)
	return (s == "unix") and x or ""
end
upath.write = function(self, section, value)
	sync_service(section)
end

ucode = ing:option(Value, "_status", translate("HTTP Status Code"))
ucode.placeholder = "404"
ucode.datatype = "uinteger"
ucode.cfgvalue = function(self, section)
	local svc = uci:get("cloudflared", section, "service") or ""
	local s, _, _, x = parse_service(svc)
	return (s == "http_status") and x or ""
end
ucode.write = function(self, section, value)
	sync_service(section)
end

local host_header = ing:option(Value, "origin_host_header", translate("Origin Host Header"),
	translate("Optional. Host header sent to the origin. Useful when the origin vhost expects a specific name."))
host_header.placeholder = "192.168.1.1"
host_header.rmempty = true

local no_tls = ing:option(Flag, "no_tls_verify", translate("Skip Origin TLS Verify"),
	translate("Enable for HTTPS origins with self-signed certificates."))
no_tls.default = "0"
no_tls.rmempty = false

local origin_name = ing:option(Value, "origin_server_name", translate("Origin TLS Server Name"),
	translate("Optional. Override the TLS server name used for HTTPS origins."))
origin_name.placeholder = "origin.example.com"
origin_name.rmempty = true

local ipath = ing:option(Value, "ingress_path", translate("Ingress Path"),
	translate("Optional. URL path prefix for HTTP/HTTPS ingress rules."))
ipath.placeholder = "/"
ipath.rmempty = true

local ctimeout = ing:option(Value, "origin_connect_timeout", translate("Connect Timeout"),
	translate("Origin connection timeout, e.g. 30s."))
ctimeout.placeholder = "30s"
ctimeout.rmempty = true

local tlstimeout = ing:option(Value, "origin_tls_timeout", translate("TLS Timeout"),
	translate("Origin TLS handshake timeout, e.g. 10s."))
tlstimeout.placeholder = "10s"
tlstimeout.rmempty = true

local tcpkeepalive = ing:option(Value, "origin_tcp_keepalive", translate("TCP KeepAlive"),
	translate("Origin TCP keepalive interval, e.g. 30s."))
tcpkeepalive.placeholder = "30s"
tcpkeepalive.rmempty = true

local nohappy = ing:option(Flag, "origin_no_happy_eyeballs", translate("Disable Happy Eyeballs"),
	translate("Disable parallel IPv4/IPv6 connection attempts."))
nohappy.default = "0"
nohappy.rmempty = false

local proxyaddr = ing:option(Value, "origin_proxy_address", translate("Proxy Address"),
	translate("Optional SOCKS/HTTP proxy address for the origin connection."))
proxyaddr.placeholder = "127.0.0.1"
proxyaddr.rmempty = true

local proxyport = ing:option(Value, "origin_proxy_port", translate("Proxy Port"),
	translate("Optional proxy port."))
proxyport.placeholder = "1080"
proxyport.datatype = "port"
proxyport.rmempty = true

local proxytype = ing:option(ListValue, "origin_proxy_type", translate("Proxy Type"),
	translate("Optional origin proxy protocol."))
proxytype:value("socks5", "SOCKS5")
proxytype:value("http", "HTTP")
proxytype.rmempty = true

local http2 = ing:option(Flag, "origin_http2", translate("HTTP/2 Origin"),
	translate("Use HTTP/2 when connecting to the origin."))
http2.default = "0"
http2.rmempty = false

local nochunk = ing:option(Flag, "origin_disable_chunked", translate("Disable Chunked Encoding"),
	translate("Disable chunked transfer encoding for HTTP origins."))
nochunk.default = "0"
nochunk.rmempty = false

local kaconns = ing:option(Value, "origin_keepalive_connections", translate("KeepAlive Connections"),
	translate("Number of keepalive connections to the origin."))
kaconns.placeholder = "100"
kaconns.datatype = "uinteger"
kaconns.rmempty = true

local katimeout = ing:option(Value, "origin_keepalive_timeout", translate("KeepAlive Timeout"),
	translate("Keepalive timeout for HTTP origins, e.g. 90s."))
katimeout.placeholder = "90s"
katimeout.rmempty = true

local capool = ing:option(Value, "origin_ca_pool", translate("CA Pool"),
	translate("Optional CA bundle path used to verify HTTPS origins."))
capool.placeholder = "/etc/ssl/certs/ca-certificates.crt"
capool.rmempty = true

local bastion = ing:option(Flag, "origin_bastion_mode", translate("Bastion Mode"),
	translate("Enable bastion mode for SSH origins."))
bastion.default = "0"
bastion.rmempty = false

local ip_hints = uci:get_list("cloudflared", "main", "common_ips") or {}
if #ip_hints > 0 then
	local js_options = ""
	for _, v in ipairs(ip_hints) do
		js_options = js_options .. '<option value="' .. v .. '">'
	end
	local inject = ing:option(DummyValue, "_ip_datalist")
	inject.rawhtml = true
	inject.width = "0"
	inject.cfgvalue = function()
		return '<datalist id="cf-common-ips">' .. js_options .. "</datalist>" ..
			"<script>" ..
			'document.querySelectorAll("input[id*=\"._ip\"]").forEach(function(el){' ..
			'el.setAttribute("list","cf-common-ips");' ..
			"});" ..
			"</script>"
	end
end

local svc_col = ing:option(DummyValue, "_service_summary", translate("Service"))
svc_col.rawhtml = true
svc_col.width = "220px"
svc_col.cfgvalue = function(self, section)
	local svc = uci:get("cloudflared", section, "service") or ""
	local scheme, host, port, extra = parse_service(svc)
	local text = "—"
	if scheme == "unix" then
		text = "unix:" .. extra
	elseif scheme == "http_status" then
		text = "http_status:" .. extra
	elseif scheme then
		text = scheme .. "://" .. host .. (port and (":" .. port) or "")
	end
	return '<span id="cf-service-' .. section .. '"><code>' .. xml.pcdata(text) .. '</code></span>'
end

local dns_col = ing:option(DummyValue, "_dns_status", translate("DNS"))
dns_col.rawhtml = true
dns_col.width = "120px"

function dns_col.cfgvalue(self, section)
	local host = uci:get("cloudflared", section, "hostname") or ""
	local ts = uci:get("cloudflared", section, "tunnel") or ""
	local t = tunnel_by_section[ts]
	local inner

	if host == "" then
		inner = "<span style='color:#ccc'>—</span>"
	elseif not t or not dns_ready[t.section] then
		inner = "<span style='color:#aaa' title='" .. translate("Cannot check: missing config") .. "'>● " .. translate("Unknown") .. "</span>"
	else
		inner = "<span style='color:#888'>● " .. translate("Checking...") .. "</span>"
	end

	return '<span id="cf-dns-' .. section .. '">' .. inner .. '</span>'
end

local test_col = ing:option(DummyValue, "_test", translate("Check"))
test_col.rawhtml = true
test_col.width = "240px"
test_col.cfgvalue = function(self, section)
	return '<button type="button" class="btn cbi-button" onclick="cfTestIngress(\'' .. section .. '\')">' ..
		translate("Test") .. '</button> <span id="cf-test-' .. section .. '" style="font-size:90%"></span>'
end


-- ===== Hooks =====

function m.on_after_commit(self)
	self.uci:commit("cloudflared")

	local snap_after = common.snapshot_tunnels()
	local changed = common.diff_snapshots(snap_before, snap_after)

	-- Always regenerate every tunnel: ingress edits do not necessarily change
	-- a tunnel signature, and an ingress may have been moved to another tunnel.
	local sections = common.tunnel_sections()
	local ok, cfg_changed = common.regen_sections(sections)

	for _, section in ipairs(changed) do
		local t = self.uci:get("cloudflared", section)
		if t then
			local enabled = self.uci:get("cloudflared", section, "enabled") or "1"
			if enabled ~= "0" then
				common.action_dns_sync({ section = section })
				common.delete_orphan_dns(section)
			end
		end
	end

	if cfg_changed then
		common.restart_service()
	end
end

return m
