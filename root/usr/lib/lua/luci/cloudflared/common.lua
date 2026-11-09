-- Shared Lua helpers for luci-app-cloudflared.

local fs = require "nixio.fs"
local sys = require "luci.sys"
local jsonc = require "luci.jsonc"
local uci = require "luci.model.uci"

local M = {}

M.CTL = "/usr/bin/cloudflared-ctl"
M.STATE_DIR = "/tmp/cloudflared"
M.LOG_DIR = "/var/log/cloudflared"

function M.shellquote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.run(args)
	local cmd = M.CTL .. " " .. args .. " 2>&1; printf '\\n__CF_EXIT:%s\\n' \"$?\""
	local out = sys.exec(cmd) or ""
	local code = tonumber(out:match("__CF_EXIT:(%d+)")) or 1
	out = out:gsub("\n?__CF_EXIT:%d+\n?", "")
	return out, code
end

function M.parse_kv(text)
	local t = {}
	if not text then
		return t
	end
	for k, v in text:gmatch("([%w_%-]+)=([^\n]*)") do
		t[k] = v
	end
	return t
end

function M.read_status(path)
	return M.parse_kv(fs.readfile(path))
end

function M.valid_domain(domain)
	if not domain or domain == "" then
		return false
	end
	if domain:match("%.%.") or domain:match("^%.") or domain:match("%.$") then
		return false
	end
	return domain:match("^[A-Za-z0-9][A-Za-z0-9%.%-]*%.[A-Za-z][A-Za-z0-9%.%-]*$") ~= nil
end

function M.section_exists(section, cfg)
	if not section or section == "" then
		return false
	end
	local cursor = cfg or uci.cursor()
	return cursor:get("cloudflared", section) ~= nil
end

function M.get_tunnel(section)
	local cursor = uci.cursor()
	local t = cursor:get_all("cloudflared", section)
	if not t then
		return nil
	end
	t[".name"] = section
	return t
end

function M.list_tunnels()
	local cursor = uci.cursor()
	local list = {}
	cursor:foreach("cloudflared", "tunnel", function(s)
		list[#list + 1] = {
			section = s[".name"],
			name = s.name or s[".name"],
			enabled = s.enabled ~= "0",
			domain = s.domain or "",
			applied_domain = s.applied_domain or s.domain or "",
			tunnel_id = s.tunnel_id or "",
			data_dir = s.data_dir or "",
			cert_path = s.cert_path or "",
			credentials_file = s.credentials_file or "",
		}
	end)
	return list
end

local function sorted_option_keys(t)
	local keys = {}
	for k in pairs(t) do
		if k:sub(1, 1) ~= "." then
			keys[#keys + 1] = k
		end
	end
	table.sort(keys)
	return keys
end

function M.tunnel_sections()
	local out = M.run("tunnel-sections")
	local list = {}
	for section in out:gmatch("%S+") do
		list[#list + 1] = section
	end
	return list
end

function M.tunnel_signature(section)
	local cursor = uci.cursor()
	local opts = cursor:get_all("cloudflared", section) or {}
	local parts = {}

	for _, key in ipairs(sorted_option_keys(opts)) do
		parts[#parts + 1] = key .. "=" .. tostring(opts[key])
	end

	local ingress = {}
	cursor:foreach("cloudflared", "ingress", function(s)
		if s.tunnel == section then
			ingress[#ingress + 1] = (s.hostname or "") .. "|" ..
				(s.service or "") .. "|" .. (s.enabled or "1")
		end
	end)
	table.sort(ingress)

	return table.concat(parts, "\n") .. "\n--\n" .. table.concat(ingress, "\n")
end

function M.snapshot_tunnels()
	local snapshot = {}
	local cursor = uci.cursor()
	cursor:foreach("cloudflared", "tunnel", function(s)
		local section = s[".name"]
		snapshot[section] = M.tunnel_signature(section)
	end)
	return snapshot
end

function M.diff_snapshots(before, after)
	local changed, added, removed = {}, {}, {}
	local all = {}

	for k in pairs(before) do all[k] = true end
	for k in pairs(after) do all[k] = true end

	local names = {}
	for k in pairs(all) do names[#names + 1] = k end
	table.sort(names)

	for _, k in ipairs(names) do
		if not before[k] then
			added[#added + 1] = k
			changed[#changed + 1] = k
		elseif not after[k] then
			removed[#removed + 1] = k
		elseif before[k] ~= after[k] then
			changed[#changed + 1] = k
		end
	end

	return changed, added, removed
end

function M.regen_sections(sections)
	local ok = true
	local changed = false
	local changed_sections = {}

	for _, section in ipairs(sections) do
		local out = M.run("get-config-path " .. M.shellquote(section))
		local path = (out or ""):gsub("%s+$", "")
		local before = ""
		local after = ""

		if path ~= "" then
			before = fs.readfile(path) or ""
		end

		local generated = M.gen_config(section)
		if not generated then
			ok = false
		end

		if path ~= "" then
			after = fs.readfile(path) or ""
		end
		if after ~= before then
			changed = true
			changed_sections[#changed_sections + 1] = section
		end
	end

	return ok, changed, changed_sections
end

function M.tunnel_domain(section)
	local cursor = uci.cursor()
	return cursor:get("cloudflared", section, "domain") or ""
end

function M.tunnel_id(section)
	local cursor = uci.cursor()
	return cursor:get("cloudflared", section, "tunnel_id") or ""
end

function M.api_token(section)
	local cursor = uci.cursor()
	local token = ""
	if section then
		token = cursor:get("cloudflared", section, "api_token") or ""
	end
	if token == "" then
		token = cursor:get("cloudflared", "main", "api_token") or ""
	end
	return token
end

function M.api_base_path()
	local cursor = uci.cursor()
	return cursor:get("cloudflared", "main", "base_path") or "/opt/cloudflare"
end

function M.find_binary()
	local cursor = uci.cursor()
	local base = cursor:get("cloudflared", "main", "base_path") or "/opt/cloudflare"
	local custom = cursor:get("cloudflared", "main", "cloudflared_path") or ""

	if custom ~= "" and fs.access(custom) then
		return custom
	end
	if fs.access(base .. "/cloudflared") then
		return base .. "/cloudflared"
	end
	local dir = fs.dir(base)
	if dir then
		for file in dir do
			if file:match("^cloudflared%-linux%-") and fs.access(base .. "/" .. file) then
				return base .. "/" .. file
			end
		end
	end
	if fs.access("/usr/bin/cloudflared") then
		return "/usr/bin/cloudflared"
	end
	return nil
end

function M.tunnel_dir(section)
	local cursor = uci.cursor()
	local base = cursor:get("cloudflared", "main", "base_path") or "/opt/cloudflare"
	local dir = cursor:get("cloudflared", section, "data_dir") or ""

	if dir ~= "" then
		return dir
	end
	if section == "default" and fs.access(base .. "/config.yml") then
		return base
	end
	return base .. "/tunnels/" .. section
end

function M.resolve_cert(section)
	local cursor = uci.cursor()
	local base = cursor:get("cloudflared", "main", "base_path") or "/opt/cloudflare"
	local path = cursor:get("cloudflared", section, "cert_path") or ""

	if path == "" then
		local dir = M.tunnel_dir(section)
		if fs.access(dir .. "/cert.pem") then
			path = dir .. "/cert.pem"
		end
	end
	if path == "" then
		path = cursor:get("cloudflared", "main", "cert_path") or ""
	end
	if path == "" then
		path = base .. "/cert.pem"
	end
	return path
end

function M.gen_config(section)
	local out, code = M.run("gen-config " .. M.shellquote(section))
	return code == 0, out
end

function M.restart_service()
	local code = sys.call("/etc/init.d/cloudflared restart >/dev/null 2>&1")
	return code == 0
end

function M.is_safe_path(path)
	if not path or path == "" then
		return false
	end
	if path:match("%.%.") then
		return false
	end
	return path:match("^/[%w%._/%-]+$") ~= nil
end

function M.cf_api(method, path, token)
	if not token or token == "" then
		return nil
	end
	local cmd = string.format(
		"curl -s --connect-timeout 5 --max-time 15 -X %s %s -H %s -H 'Content-Type: application/json' 2>/dev/null",
		method,
		M.shellquote("https://api.cloudflare.com/client/v4" .. path),
		M.shellquote("Authorization: Bearer " .. token)
	)
	local result = sys.exec(cmd)
	if not result or result == "" then
		return nil
	end
	return jsonc.parse(result)
end

function M.get_zone_id(token, domain)
	if not domain or domain == "" then
		return nil
	end
	local data = M.cf_api("GET", "/zones?name=" .. domain, token)
	if data and data.success and data.result and #data.result > 0 then
		return data.result[1].id
	end
	return nil
end

function M.fetch_tunnel_dns(token, tunnel_id, domain)
	local records = {}
	if not token or not tunnel_id or not domain then
		return records, false
	end

	local zone_id = M.get_zone_id(token, domain)
	if not zone_id then
		return records, false
	end

	local target = tunnel_id .. ".cfargotunnel.com"
	local data = M.cf_api("GET",
		"/zones/" .. zone_id .. "/dns_records?type=CNAME&per_page=100", token)
	if data and data.success and data.result then
		for _, r in ipairs(data.result) do
			if r.content == target then
				records[r.name] = { id = r.id, zone_id = zone_id }
			end
		end
		return records, true
	end
	return records, false
end

function M.delete_orphan_dns(section)
	local cursor = uci.cursor()
	local allow = cursor:get("cloudflared", "main", "allow_dns_delete") or "0"

	if allow ~= "1" then
		return { ok = true, deleted = 0, message = "DNS deletion disabled" }
	end

	local token = M.api_token(section)
	local tunnel_id = cursor:get("cloudflared", section, "tunnel_id") or ""
	local domain = cursor:get("cloudflared", section, "domain") or ""

	if token == "" or tunnel_id == "" or domain == "" then
		return { ok = false, deleted = 0, message = "Missing API token, tunnel ID or domain" }
	end

	local hosts = {}
	cursor:foreach("cloudflared", "ingress", function(s)
		if s.tunnel == section and s.hostname and s.hostname ~= "" then
			hosts[s.hostname] = true
		end
	end)

	local records = M.fetch_tunnel_dns(token, tunnel_id, domain)
	local deleted = 0

	for host, info in pairs(records) do
		if not hosts[host] then
			local result = M.cf_api("DELETE",
				"/zones/" .. info.zone_id .. "/dns_records/" .. info.id, token)
			if result and result.success then
				deleted = deleted + 1
			end
		end
	end

	return { ok = true, deleted = deleted, message = "Deleted " .. deleted .. " DNS record(s)" }
end

function M.regenerate_all()
	local ok = true
	local out = M.run("tunnel-sections")
	for section in out:gmatch("%S+") do
		local generated = M.gen_config(section)
		if not generated then
			ok = false
		end
	end
	return ok
end

function M.action_domain_switch(p)
	local section = p.section or ""
	local new = p.new_domain or ""

	if not M.section_exists(section) then
		return { ok = false, message = "Unknown tunnel: " .. section }
	end
	if not M.valid_domain(new) then
		return { ok = false, message = "Invalid domain: " .. new }
	end

	local function enabled(value)
		return value == nil or value == "1" or value == true or value == "true"
	end

	local command = string.format("domain-switch %s %s",
		M.shellquote(section), M.shellquote(new))

	if not enabled(p.rewrite_hosts) then
		command = command .. " --no-rewrite-hosts"
	end
	if not enabled(p.sync_dns) then
		command = command .. " --no-dns-sync"
	end
	if not enabled(p.restart) then
		command = command .. " --no-restart"
	end

	local out, code = M.run(command)

	return {
		ok = code == 0,
		message = out,
		old = out:match("old=(%S*)") or "",
		new = new,
		rewritten = tonumber(out:match("rewritten=(%d+)")) or 0,
		dns_created = tonumber(out:match("dns_created=(%d+)")) or 0,
		restarted = out:match("restarted=(%d+)") == "1",
	}
end

function M.action_dns_sync(p)
	local section = p.section or ""
	if not M.section_exists(section) then
		return { ok = false, message = "Unknown tunnel: " .. section }
	end

	local tunnels = M.list_tunnels()
	local hosts = {}
	local cursor = uci.cursor()

	cursor:foreach("cloudflared", "ingress", function(rule)
		local target = M.resolve_ingress_tunnel(tunnels, rule.tunnel or "")
		local host = rule.hostname or ""
		if target == section and (rule.enabled or "1") ~= "0" and host ~= "" then
			hosts[host] = true
		end
	end)

	local created, exists, failed = {}, {}, {}

	for host in pairs(hosts) do
		local out = M.run(string.format("dns-sync-host %s %s",
			M.shellquote(section), M.shellquote(host)))
		local info = M.parse_kv(out)
		local state = info.status or "failed"

		if state == "created" then
			created[#created + 1] = host
		elseif state == "exists" then
			exists[#exists + 1] = host
		else
			failed[#failed + 1] = host
		end
	end

	table.sort(created)
	table.sort(exists)
	table.sort(failed)

	return {
		ok = #failed == 0,
		section = section,
		total = #created + #exists + #failed,
		created = created,
		exists = exists,
		failed = failed,
		created_count = #created,
		exists_count = #exists,
		failed_count = #failed,
		message = string.format("created=%d exists=%d failed=%d",
			#created, #exists, #failed),
	}
end

function M.core_asset()
	local out, code = M.run("core-asset")
	return M.parse_kv(out), code == 0
end

function M.core_target()
	local cursor = uci.cursor()
	local base = cursor:get("cloudflared", "main", "base_path") or "/opt/cloudflare"
	local custom = cursor:get("cloudflared", "main", "cloudflared_path") or ""

	if custom ~= "" then
		return custom
	end
	if fs.access(base .. "/cloudflared") then
		return base .. "/cloudflared"
	end
	if fs.access("/usr/bin/cloudflared") then
		return "/usr/bin/cloudflared"
	end
	return base .. "/cloudflared"
end

function M.action_core_check()
	local bin = M.find_binary()
	if not bin then
		return {
			ok = true,
			installed = false,
			up_to_date = false,
			current = "",
			latest = "",
			binary = "",
		}
	end

	local status = M.parse_kv((M.run("core-status")))
	local current = status.current_version or ""
	local latest = M.latest_version(false)

	return {
		ok = true,
		installed = true,
		up_to_date = current ~= "" and latest ~= "" and current == latest,
		current = current,
		latest = latest,
		binary = bin,
	}
end

function M.action_core_upload(path)
	if not path or path == "" or not fs.access(path) then
		return { ok = false, message = "No uploaded file" }
	end

	local size = fs.stat(path, "size") or 0
	if size < 1048576 then
		os.remove(path)
		return { ok = false, message = "Uploaded file is too small to be a cloudflared binary" }
	end

	sys.call("chmod 755 " .. M.shellquote(path) .. " 2>/dev/null")

	local out = sys.exec(M.shellquote(path) .. " --version 2>&1") or ""
	local ver = out:match("[0-9]+%.[0-9]+%.[0-9]+")
	if not ver then
		os.remove(path)
		return { ok = false, message = "Uploaded file is not a valid cloudflared binary" }
	end

	local target = M.core_target()
	local dir = target:match("^(.*)/[^/]+$")
	if dir and dir ~= "" then
		sys.call("mkdir -p " .. M.shellquote(dir) .. " 2>/dev/null")
	end
	if fs.access(target) then
		sys.call("cp -f " .. M.shellquote(target) .. " " .. M.shellquote(target .. ".old") .. " 2>/dev/null")
	end

	local moved = os.rename(path, target)
	if not moved then
		moved = sys.call("mv -f " .. M.shellquote(path) .. " " .. M.shellquote(target) .. " 2>/dev/null") == 0
	end
	if not moved then
		os.remove(path)
		return { ok = false, message = "Failed to install uploaded core to " .. target }
	end

	sys.call("chmod 755 " .. M.shellquote(target) .. " 2>/dev/null")

	local cursor = uci.cursor()
	cursor:set("cloudflared", "main", "cloudflared_path", target)
	cursor:commit("cloudflared")

	fs.mkdirr(M.STATE_DIR)
	fs.writefile(M.STATE_DIR .. "/core-install.status",
		"state=done\nversion=" .. ver .. "\ntarget=" .. target ..
		"\nmessage=Installed uploaded version " .. ver .. "\n")

	return {
		ok = true,
		state = "done",
		version = ver,
		binary = target,
		message = "Installed uploaded version " .. ver,
	}
end

function M.action_core_install(p)
	local force = (p.force == "1" or p.force == "true")

	if not force then
		local check = M.action_core_check()
		if check.installed and check.current ~= "" and check.latest ~= "" and
		   check.current == check.latest then
			return { ok = false, message = "Already the latest version" }
		end
	end

	fs.mkdirr(M.STATE_DIR)
	local status = M.STATE_DIR .. "/core-install.status"
	fs.writefile(status, "state=starting\nversion=\ntarget=\nmessage=Starting download\n")
	fs.writefile(M.STATE_DIR .. "/core-install.started", tostring(os.time()) .. "\n")
	os.remove(M.STATE_DIR .. "/core-install.pid")

	local url = p.url or ""
	local cmd = "/usr/bin/setsid " .. M.CTL .. " core-install"
	if url ~= "" then
		cmd = cmd .. " " .. M.shellquote(url)
	end
	cmd = cmd .. " >/dev/null 2>&1 &"
	sys.call(cmd)

	return { ok = true, state = "starting", message = "Install started" }
end

function M.action_core_status()
	local status = M.read_status(M.STATE_DIR .. "/core-install.status")
	local out = M.run("core-status")
	local parsed = M.parse_kv(out)
	for k, v in pairs(parsed) do
		status[k] = v
	end

	return {
		ok = true,
		state = status.state or "idle",
		version = status.version or "",
		current_version = status.current_version or "",
		target = status.target or "",
		binary = status.binary or "",
		message = status.message or "",
	}
end

function M.action_login_start(p)
	local section = p.section or ""
	if not M.section_exists(section) then
		return { ok = false, message = "Unknown tunnel: " .. section }
	end

	local force = (p.force == "1" or p.force == "true") and "1" or "0"
	local out, code = M.run(string.format("login-start %s %s",
		M.shellquote(section), force))
	local status = M.read_status(M.STATE_DIR .. "/login-" .. section .. ".status")

	return {
		ok = code == 0,
		state = status.state or "",
		url = status.url or "",
		message = status.message or out,
	}
end

function M.action_login_status(p)
	local section = p.section or ""
	if not M.section_exists(section) then
		return { ok = false, message = "Unknown tunnel: " .. section }
	end

	local out, code = M.run("login-status " .. M.shellquote(section))
	local status = M.parse_kv(out)

	return {
		ok = code == 0,
		state = status.state or "",
		url = status.url or "",
		cert = status.cert or "",
		message = status.message or "",
	}
end

function M.action_tunnel_create(p)
	local section = p.section or ""
	if not M.section_exists(section) then
		return { ok = false, message = "Tunnel not saved yet; save it first" }
	end

	local cursor = uci.cursor()
	local existing = cursor:get("cloudflared", section, "tunnel_id") or ""
	if existing ~= "" and p.force ~= "1" then
		return { ok = false, message = "Tunnel already has an ID; force required" }
	end

	local args = M.shellquote(section)
	if p.name and p.name ~= "" then
		args = args .. " " .. M.shellquote(p.name)
	end

	local out, code = M.run("tunnel-create " .. args)
	if code ~= 0 then
		return { ok = false, message = out }
	end

	local info = M.parse_kv(out)
	return {
		ok = true,
		tunnel_id = info.tunnel_id or "",
		credentials = info.credentials or "",
		name = info.name or "",
		message = out,
	}
end

function M.action_upload(kind, section, path)
	if not M.section_exists(section) then
		return { ok = false, message = "Unknown tunnel: " .. section }
	end
	if not path or path == "" or not fs.access(path) then
		return { ok = false, message = "Uploaded file not found" }
	end

	local content = fs.readfile(path) or ""
	if kind == "cert" then
		if not content:match("BEGIN CERTIFICATE") then
			return { ok = false, message = "Not a PEM certificate" }
		end
	else
		local creds = jsonc.parse(content)
		if not creds or not creds.TunnelID or not creds.TunnelSecret or not creds.AccountTag then
			return { ok = false, message = "Invalid tunnel credentials JSON" }
		end
	end

	local command = (kind == "cert") and "install-cert" or "install-credentials"
	local out, code = M.run(string.format("%s %s %s",
		command, M.shellquote(section), M.shellquote(path)))

	return { ok = code == 0, message = out }
end

function M.parse_service(service)
	if not service or service == "" then
		return nil
	end

	local scheme, rest = service:match("^([%w_]+):(.+)$")
	if not scheme then
		return nil
	end
	if scheme == "unix" then
		return "unix", "", nil, rest
	end
	if scheme == "http_status" then
		return "http_status", "", nil, rest
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
		return nil
	end

	port = tonumber(port) or ((scheme == "https") and 443 or 80)
	return scheme, host, port, rest
end

function M.test_backend(scheme, host, port, extra, host_header, no_tls, server_name, ca_pool)
	if scheme == "http" or scheme == "https" then
		local portnum = tostring(port or ((scheme == "https") and 443 or 80))
		local hostpart = host
		if hostpart and hostpart:find(":") then
			hostpart = "[" .. hostpart .. "]"
		end

		local sni = server_name
		if not sni or sni == "" then
			sni = host_header
		end
		if not sni or sni == "" then
			sni = host
		end

		local connect_host = hostpart
		local resolve = ""
		if scheme == "https" and sni and sni ~= "" and sni ~= host and
		   not sni:find(":") and sni:match("%a") and
		   host and host ~= "" and not host:find(":") then
			-- Connect with the proper TLS SNI while still dialling the origin IP.
			connect_host = sni
			resolve = " --resolve " .. M.shellquote(sni .. ":" .. portnum .. ":" .. host)
		end

		local url = scheme .. "://" .. connect_host .. ":" .. portnum .. "/"
		local hdr = ""
		if host_header and host_header ~= "" then
			hdr = " -H " .. M.shellquote("Host: " .. host_header)
		end

		local tls_opts = ""
		if scheme == "https" then
			if no_tls == "1" then
				tls_opts = " -k"
			elseif ca_pool and ca_pool ~= "" then
				tls_opts = " --cacert " .. M.shellquote(ca_pool)
			end
		end

		local out = sys.exec("curl" .. tls_opts .. resolve ..
			" -sS -o /dev/null -w '%{http_code}' --max-time 5" ..
			hdr .. " " .. M.shellquote(url) .. " 2>/dev/null")
		out = (out or ""):gsub("%s+$", "")
		if out ~= "" and out ~= "000" then
			return true, "HTTP " .. out, tonumber(out)
		end
		return false, "HTTP connection failed", nil
	elseif scheme == "unix" then
		local ok, err = pcall(function()
			local nixio = require "nixio"
			local sock = nixio.socket("unix", "stream")
			if not sock then
				error("socket unavailable")
			end
			local r, e = sock:connect(extra)
			sock:close()
			if not r then
				error(e or "connect failed")
			end
		end)
		return ok, ok and "Unix socket reachable" or ("Unix socket failed: " .. tostring(err))
	elseif scheme == "http_status" then
		return true, "Synthetic HTTP status " .. tostring(extra)
	else
		local code = sys.call("nc -w 3 " .. M.shellquote(host or "") .. " " ..
			tostring(port or 0) .. " < /dev/null >/dev/null 2>&1")
		return code == 0, code == 0 and "TCP connect OK" or "TCP connect failed"
	end
end

function M.cached_tunnel_dns(section, token, tunnel_id, domain)
	local key = "v2-" .. section .. "-" .. tunnel_id .. "-" .. domain
	local path = M.STATE_DIR .. "/dns-" .. key .. ".cache"
	local mtime = fs.stat(path, "mtime")
	local now = os.time()

	if mtime and (now - mtime) < 60 then
		local records = {}
		local data = fs.readfile(path) or ""
		for host in data:gmatch("[^\n]+") do
			records[host] = true
		end
		return records, true
	end

	local records, success = M.fetch_tunnel_dns(token, tunnel_id, domain)
	if success == false then
		return records, false
	end
	local hosts = {}
	for host in pairs(records) do
		hosts[#hosts + 1] = host
	end
	fs.mkdirr(M.STATE_DIR)
	fs.writefile(path, table.concat(hosts, "\n"))
	return records, true
end

function M.resolve_ingress_tunnel(tunnels, ts)
	if not ts or ts == "" then
		if #tunnels == 1 then
			return tunnels[1].section
		end
		return ""
	end

	for _, t in ipairs(tunnels) do
		if t.section == ts then
			return ts
		end
	end

	-- Tolerate legacy references (display name or tunnel UUID).
	for _, t in ipairs(tunnels) do
		if t.name == ts or t.tunnel_id == ts then
			return t.section
		end
	end

	if #tunnels == 1 then
		return tunnels[1].section
	end

	return ""
end

function M.action_ingress_dns()
	local cursor = uci.cursor()
	local tunnels = {}

	cursor:foreach("cloudflared", "tunnel", function(sec)
		local token = sec.api_token or ""
		if token == "" then
			token = cursor:get("cloudflared", "main", "api_token") or ""
		end
		tunnels[#tunnels + 1] = {
			section = sec[".name"],
			name = sec.name or "",
			domain = sec.domain or "",
			tunnel_id = sec.tunnel_id or "",
			token = token,
		}
	end)

	local records = {}
	local ready = {}
	for _, t in ipairs(tunnels) do
		if t.token ~= "" and t.domain ~= "" and t.tunnel_id ~= "" then
			local r, success = M.cached_tunnel_dns(t.section, t.token, t.tunnel_id, t.domain)
			ready[t.section] = success ~= false
			records[t.section] = {}
			for host in pairs(r) do
				records[t.section][host] = true
			end
		end
	end

	local status = {}
	cursor:foreach("cloudflared", "ingress", function(sec)
		local section = sec[".name"]
		local host = sec.hostname or ""
		local ts = M.resolve_ingress_tunnel(tunnels, sec.tunnel or "")
		local st
		if host == "" then
			st = "none"
		elseif sec.enabled == "0" then
			st = "disabled"
		elseif not ready[ts] then
			st = "unknown"
		elseif records[ts] and records[ts][host] then
			st = "synced"
		else
			st = "pending"
		end
		status[section] = st
	end)

	local allow = cursor:get("cloudflared", "main", "allow_dns_delete") == "1"
	local orphaned = {}
	if allow then
		local ingress_hosts = {}
		cursor:foreach("cloudflared", "ingress", function(sec)
			if sec.tunnel and sec.hostname and sec.hostname ~= "" then
				ingress_hosts[sec.tunnel] = ingress_hosts[sec.tunnel] or {}
				ingress_hosts[sec.tunnel][sec.hostname] = true
			end
		end)
		for section, tunnel_records in pairs(records) do
			local hosts = ingress_hosts[section]
			for host in pairs(tunnel_records) do
				if not hosts or not hosts[host] then
					orphaned[#orphaned + 1] = host .. " (" .. section .. ")"
				end
			end
		end
	end

	return {
		ok = true,
		status = status,
		orphaned = orphaned,
		allow_delete = allow,
	}
end

-- Classify each rule once; process state and DNS do not prove origin health.
function M.site_state(rule, tunnel, dns_state, running)
	if rule.enabled == "0" or (tunnel and tunnel.enabled == false) then
		return "disabled"
	end
	if not tunnel or tunnel.tunnel_id == "" or not M.valid_domain(tunnel.domain) or
	   not M.valid_domain((rule.hostname or ""):gsub("^%*%.", "")) then
		return "abnormal"
	end
	local scheme, host, port, extra = M.parse_service(rule.service or "")
	local supported = { http = true, https = true, tcp = true, ssh = true, rdp = true, smb = true }
	local valid
	if scheme == "unix" then
		valid = extra and extra:sub(1, 1) == "/"
	elseif scheme == "http_status" then
		local code = tonumber(extra)
		valid = code and code == math.floor(code) and code >= 100 and code <= 599
	else
		valid = supported[scheme or ""] and host ~= "" and port and port >= 1 and port <= 65535
	end
	if not valid or not running or (dns_state ~= "synced" and dns_state ~= "pending") then
		return "abnormal"
	end
	return dns_state == "pending" and "pending" or "running"
end

function M.action_site_stats()
	local cursor = uci.cursor()
	local tunnels = M.list_tunnels()
	local by_section = {}
	for _, tunnel in ipairs(tunnels) do
		by_section[tunnel.section] = tunnel
	end
	local dns = M.action_ingress_dns().status or {}
	local instances = M.ubus_instances()
	local counts = { total = 0, running = 0, pending = 0, abnormal = 0, disabled = 0 }
	cursor:foreach("cloudflared", "ingress", function(rule)
		local section = M.resolve_ingress_tunnel(tunnels, rule.tunnel or "")
		local instance = instances["tunnel_" .. section]
		local state = M.site_state(rule, by_section[section], dns[rule[".name"]],
			instance ~= nil and instance.running == true)
		counts[state] = counts[state] + 1
		counts.total = counts.total + 1
	end)
	return { ok = true, counts = counts }
end

function M.action_test_ingress(p)
	local cursor = uci.cursor()
	local section = p.section or ""
	local service = cursor:get("cloudflared", section, "service") or ""
	local hostname = cursor:get("cloudflared", section, "hostname") or ""
	local tsec = cursor:get("cloudflared", section, "tunnel") or ""

	if cursor:get("cloudflared", section, "enabled") == "0" then
		return { ok = false, disabled = true, message = "Rule disabled" }
	end

	if service == "" then
		return { ok = false, message = "No service configured" }
	end

	local scheme, host, port, extra = M.parse_service(service)
	if not scheme then
		return { ok = false, message = "Invalid service: " .. service }
	end

	local host_header = cursor:get("cloudflared", section, "origin_host_header") or ""
	if host_header == "" then
		host_header = hostname
	end
	local no_tls = cursor:get("cloudflared", section, "no_tls_verify") or "0"
	local origin_name = cursor:get("cloudflared", section, "origin_server_name") or ""
	local ca_pool = cursor:get("cloudflared", section, "origin_ca_pool") or ""

	local backend_ok, backend_msg, backend_code = M.test_backend(scheme, host, port, extra,
		host_header, no_tls, origin_name, ca_pool)
	local tunnel_section = M.resolve_ingress_tunnel(M.list_tunnels(), tsec)
	local tunnel_running = M.tunnel_running(tunnel_section)
	local backend_healthy = backend_ok and
		(backend_code == nil or (backend_code >= 200 and backend_code < 400))
	local result = {
		ok = backend_healthy,
		service = service,
		scheme = scheme,
		backend = backend_msg,
		backend_code = backend_code,
		level = backend_healthy and "ok" or (backend_ok and "warn" or "error"),
		tunnel_running = tunnel_running,
	}

	if tsec ~= "" then
		local token = cursor:get("cloudflared", tsec, "api_token") or
			cursor:get("cloudflared", "main", "api_token") or ""
		local tid = cursor:get("cloudflared", tsec, "tunnel_id") or ""
		local domain = cursor:get("cloudflared", tsec, "domain") or ""
		if token ~= "" and tid ~= "" and domain ~= "" and hostname ~= "" then
			local records = M.fetch_tunnel_dns(token, tid, domain)
			result.dns_ok = records[hostname] ~= nil
			result.dns = result.dns_ok and "CNAME exists" or "CNAME missing"
		else
			result.dns = "DNS check unavailable"
		end
	end

	if (scheme == "http" or scheme == "https") and hostname ~= "" then
		local out = sys.exec("curl -4 --noproxy '*' -k -sS -o /dev/null -w '%{http_code}' --max-time 8 " ..
			M.shellquote("https://" .. hostname .. "/") .. " 2>/dev/null")
		out = (out or ""):gsub("%s+$", "")
		local code = tonumber(out)

		if code and code >= 200 and code < 400 then
			result.public_status = "HTTP " .. out
			result.public_level = "ok"
		elseif code and code >= 400 and code < 500 then
			result.public_status = "HTTP " .. out
			result.public_level = "warn"
		elseif code and code >= 500 then
			result.public_status = "HTTP " .. out
			result.public_level = "error"
		else
			local resolved = sys.call("nslookup " .. M.shellquote(hostname) ..
				" >/dev/null 2>&1") == 0
			result.public_status = resolved and "unreachable" or "DNS resolution failed"
			result.public_level = "error"
		end
	end

	result.message = backend_msg
	result.ok = backend_healthy and tunnel_running and (result.dns_ok ~= false)
	return result
end

function M.action_service(p)
	local op = p.op or ""
	if op ~= "start" and op ~= "stop" and op ~= "restart" then
		return { ok = false, message = "Invalid operation" }
	end

	if op == "start" or op == "restart" then
		local info = M.parse_kv(M.run("check"))
		if info.ok ~= "1" then
			return { ok = false, message = info.message or "Preflight check failed" }
		end
	end

	local code = sys.call("/etc/init.d/cloudflared " .. op .. " >/dev/null 2>&1")

	if op == "start" or op == "restart" then
		local running = false
		for _ = 1, 10 do
			sys.call("sleep 1")
			if sys.call("pgrep -f 'cloudflared.*tunnel run' >/dev/null 2>&1") == 0 then
				running = true
				break
			end
		end
		if not running then
			return {
				ok = false,
				message = "Service did not start; check the log for details",
			}
		end
	end

	return { ok = code == 0, message = "Service " .. op .. " requested" }
end

function M.update_log_cron()
	sys.call("/usr/bin/cloudflared-log-cron >/dev/null 2>&1")
end

function M.log_path(which)
	return (which == "core") and (M.LOG_DIR .. "/core.log") or (M.LOG_DIR .. "/app.log")
end

function M.action_get_log(p)
	local which = (p.which == "core") and "core" or "app"
	local path = M.log_path(which)
	local lines = tonumber(p.lines) or 500
	local pattern = p.filter or ""

	if lines < 50 then lines = 50 end
	if lines > 5000 then lines = 5000 end

	if not fs.access(path) then
		return { ok = true, log = "", path = path, which = which }
	end

	local cmd
	if pattern ~= "" then
		cmd = "tail -n " .. tostring(lines) .. " " .. M.shellquote(path) ..
			" | grep -E -- " .. M.shellquote(pattern) .. " 2>&1; echo __CF_GREP:$?"
	else
		cmd = "tail -n " .. tostring(lines) .. " " .. M.shellquote(path) .. " 2>/dev/null"
	end

	local out = sys.exec(cmd) or ""
	if pattern ~= "" then
		local code = out:match("__CF_GREP:(%d+)")
		out = out:gsub("\n?__CF_GREP:%d+\n?", "")
		if code == "2" then
			return {
				ok = false,
				message = "Invalid filter expression",
				path = path,
				which = which,
			}
		end
	end

	return { ok = true, log = out, path = path, which = which }
end

function M.action_clear_log(p)
	local which = (p.which == "core") and "core" or "app"
	local path = M.log_path(which)
	sys.call(": > " .. M.shellquote(path) .. " 2>/dev/null")
	return { ok = true, message = "Log cleared", which = which }
end

function M.action_service_enable(p)
	local enable = (p.enabled == "1" or p.enabled == "true")
	local action = enable and "enable" or "disable"
	local code = sys.call("/etc/init.d/cloudflared " .. action .. " >/dev/null 2>&1")
	local enabled = fs.access("/etc/rc.d/S99cloudflared") and true or false

	return {
		ok = code == 0,
		enabled = enabled,
		message = enable and "Service enabled on boot" or "Service disabled on boot",
	}
end

function M.js_helpers()
	local dsp = require "luci.dispatcher"
	local action_url = dsp.build_url("admin", "services", "cloudflared", "action") or ""
	return [[
<script>
window.cfActionUrl = function() { return ]] .. jsonc.stringify(action_url) .. [[; };
window.cfToken = function() {
	if (window.L && L.env && L.env.token)
		return L.env.token;
	var e = document.querySelector('input[name="token"]');
	return e ? e.value : "";
};
window.cfAction = window.cfAction || function(action, params) {
	params = params || {};
	params.action = action;
	params.token = window.cfToken();
	var body = new URLSearchParams();
	for (var k in params) {
		if (params[k] !== undefined && params[k] !== null) body.append(k, params[k]);
	}
	var btn = document.activeElement;
	if (btn && btn.tagName === "BUTTON") btn.disabled = true;
	var finish = function(r) {
		if (btn && btn.tagName === "BUTTON") btn.disabled = false;
		return r;
	};
	return fetch(window.cfActionUrl(), {
		method: "POST",
		headers: { "Content-Type": "application/x-www-form-urlencoded" },
		body: body.toString(),
		credentials: "same-origin"
	}).then(function(r) {
		return r.text().then(function(text) {
			try {
				return JSON.parse(text);
			} catch (e) {
				return { ok: false,
				         message: "HTTP " + r.status + " " + (r.statusText || "") +
				                  " (invalid response)" };
			}
		});
	}).catch(function(e) {
		return { ok: false, message: String(e) };
	}).then(finish);
};
window.cfUpload = window.cfUpload || function(action, section, file) {
	var fd = new FormData();
	fd.append("action", action);
	fd.append("section", section);
	fd.append("token", window.cfToken());
	fd.append("file", file);
	return fetch(window.cfActionUrl(), {
		method: "POST",
		body: fd,
		credentials: "same-origin"
	}).then(function(r) {
		return r.text().then(function(text) {
			try {
				return JSON.parse(text);
			} catch (e) {
				return { ok: false,
				         message: "HTTP " + r.status + " " + (r.statusText || "") +
				                  " (invalid response)" };
			}
		});
	}).catch(function(e) {
		return { ok: false, message: String(e) };
	});
};
</script>
]]
end


function M.ubus_instances()
	local out = sys.exec("ubus call service list '{\"name\":\"cloudflared\"}' 2>/dev/null") or ""
	local parsed = jsonc.parse(out) or {}
	local service = parsed.cloudflared or {}
	return service.instances or {}
end

function M.tunnel_running(section)
	if not section or section == "" then
		return false
	end
	local inst = M.ubus_instances()["tunnel_" .. section]
	return inst ~= nil and inst.running == true
end

function M.latest_version(force)
	local path = M.STATE_DIR .. "/core-latest.cache"
	local mtime = fs.stat(path, "mtime")

	if not force and mtime and (os.time() - mtime) < 300 then
		local cached = (fs.readfile(path) or ""):gsub("%s+$", "")
		if cached ~= "" then
			return cached
		end
	end

	local out, code = M.run("core-latest")
	local latest = ""
	if code == 0 then
		latest = (out:match("latest=([^\n]+)") or ""):gsub("^v", ""):gsub("%s+$", "")
	end

	if latest ~= "" then
		fs.mkdirr(M.STATE_DIR)
		fs.writefile(path, latest .. "\n")
	end

	return latest
end

function M.action_core_cancel()
	local pid = (fs.readfile(M.STATE_DIR .. "/core-install.pid") or ""):match("(%d+)")
	if pid then
		sys.call("kill " .. pid .. " >/dev/null 2>&1")
	end

	fs.mkdirr(M.STATE_DIR)
	fs.writefile(M.STATE_DIR .. "/core-install.status",
		"state=failed\nmessage=Cancelled\n")

	return { ok = true, message = "Install cancelled" }
end


function M.tunnel_state(tunnel, running)
	if not tunnel.enabled then
		return "disabled"
	end

	local domain = tunnel.domain or ""
	local applied = tunnel.applied_domain or domain
	if domain ~= "" and applied ~= domain then
		return "pending"
	end

	if not running then
		return "abnormal"
	end

	return "running"
end

function M.tunnel_counts(tunnels, instances)
	local counts = { total = 0, running = 0, pending = 0, abnormal = 0, disabled = 0 }

	for _, tunnel in ipairs(tunnels) do
		local instance = instances["tunnel_" .. tunnel.section]
		local state = M.tunnel_state(tunnel, instance ~= nil and instance.running == true)
		counts[state] = counts[state] + 1
		counts.total = counts.total + 1
	end

	return counts
end

function M.action_tunnel_status()
	local tunnels = M.list_tunnels()
	local instances = M.ubus_instances()
	local status = {}

	for _, tunnel in ipairs(tunnels) do
		local instance = instances["tunnel_" .. tunnel.section]
		local running = instance ~= nil and instance.running == true
		status[tunnel.section] = {
			state = M.tunnel_state(tunnel, running),
			running = running,
			enabled = tunnel.enabled,
			domain = tunnel.domain,
			applied_domain = tunnel.applied_domain or tunnel.domain,
			tunnel_id = tunnel.tunnel_id,
		}
	end

	return {
		ok = true,
		status = status,
		counts = M.tunnel_counts(tunnels, instances),
	}
end

function M.action_overview()
	local cursor = uci.cursor()
	local tunnels, tunnels_enabled = 0, 0
	cursor:foreach("cloudflared", "tunnel", function(sec)
		tunnels = tunnels + 1
		if (sec.enabled or "1") ~= "0" then
			tunnels_enabled = tunnels_enabled + 1
		end
	end)

	local bin = M.find_binary()
	local version = ""
	if bin then
		version = M.run("version") or ""
		version = version:match("[0-9]+%.[0-9]+%.[0-9]+") or ""
	end

	local arch = (sys.exec("uname -m") or ""):gsub("%s+$", "")
	local asset = M.core_asset() or {}
	local tunnel_counts = M.tunnel_counts(M.list_tunnels(), M.ubus_instances())
	return {
		ok = true,
		tunnel_counts = tunnel_counts,
		asset_url = asset.url or "",
		asset_name = asset.asset or "",
		running = sys.call("pgrep -f 'cloudflared.*tunnel run' >/dev/null 2>&1") == 0,
		service_enabled = fs.access("/etc/rc.d/S99cloudflared") and true or false,
		tunnels = tunnels,
		tunnels_enabled = tunnels_enabled,
		binary = bin or "",
		version = version,
		arch = arch,
		base = cursor:get("cloudflared", "main", "base_path") or "/opt/cloudflare",
	}
end

function M.action_apply_config()
	local cursor = uci.cursor()
	cursor:commit("cloudflared")
	cursor = uci.cursor()
	local sections = M.tunnel_sections()
	local ok, changed, changed_sections = M.regen_sections(sections)

	if changed then
		local preflight = M.parse_kv(M.run("check"))
		if preflight.ok ~= "1" then
			return {
				ok = false,
				message = preflight.message or "Configuration preflight check failed",
			}
		end
	end

	for _, section in ipairs(changed_sections or {}) do
		if (cursor:get("cloudflared", section, "enabled") or "1") ~= "0" then
			M.action_dns_sync({ section = section })
			M.delete_orphan_dns(section)
		end
	end

	if changed then
		M.restart_service()
	end

	return { ok = true, restarted = changed and true or false }
end

function M.action_apply_tunnels()
	local cursor = uci.cursor()
	cursor:commit("cloudflared")
	cursor = uci.cursor()
	local sections = {}

	cursor:foreach("cloudflared", "tunnel", function(sec)
		local section = sec[".name"]
		sections[#sections + 1] = section

		local domain = sec.domain or ""
		local applied = sec.applied_domain or domain
		if domain ~= "" and domain ~= applied then
			M.action_domain_switch({
				section = section,
				new_domain = domain,
				restart = "0",
			})
		end
	end)

	local ok, changed = M.regen_sections(sections)
	local need_restart = changed
	local instances = M.ubus_instances()
	local known = {}

	for _, section in ipairs(sections) do
		known["tunnel_" .. section] = true
		if (cursor:get("cloudflared", section, "enabled") or "1") ~= "0" and
		   not instances["tunnel_" .. section] then
			need_restart = true
		end
	end

	for name in pairs(instances) do
		if name:match("^tunnel_") and not known[name] then
			need_restart = true
		end
	end

	if need_restart then
		M.restart_service()
	end

	return { ok = true, restarted = need_restart }
end

function M.action_apply_log()
	uci.cursor():commit("cloudflared")
	M.update_log_cron()
	return { ok = true }
end

return M
