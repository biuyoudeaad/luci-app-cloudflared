module("luci.controller.cloudflared", package.seeall)

function index()
	entry({"admin", "services", "cloudflared"},
		alias("admin", "services", "cloudflared", "overview"),
		_("Cloudflared"), 90).dependent = true

	entry({"admin", "services", "cloudflared", "overview"},
		cbi("cloudflared/overview"), _("Overview"), 1)

	entry({"admin", "services", "cloudflared", "tunnels"},
		cbi("cloudflared/tunnels"), _("Tunnels"), 2)

	entry({"admin", "services", "cloudflared", "ingress"},
		cbi("cloudflared/ingress"), _("Ingress"), 3)

	entry({"admin", "services", "cloudflared", "log"},
		cbi("cloudflared/log"), _("Log"), 4)

	entry({"admin", "services", "cloudflared", "action"},
		post("action"), nil).leaf = true
end

function action()
	local http = require "luci.http"
	local jsonc = require "luci.jsonc"
	local common = require "luci.cloudflared.common"

	local p = {
		action = http.formvalue("action") or "",
		section = http.formvalue("section") or "",
		name = http.formvalue("name") or "",
		new_domain = http.formvalue("new_domain") or "",
		url = http.formvalue("url") or "",
		op = http.formvalue("op") or "",
		enabled = http.formvalue("enabled") or "",
		which = http.formvalue("which") or "app",
		filter = http.formvalue("filter") or "",
		lines = http.formvalue("lines") or "",
		force = http.formvalue("force") or "",
	}

	local name = p.action
	local result

	if name == "core_upload" then
		local tmp = "/tmp/cloudflared-upload-" .. tostring(os.time()) ..
			"-" .. tostring(math.random(100000))
		local fd = nil
		local got = false
		local total = 0
		local too_big = false
		local max_size = 128 * 1024 * 1024

		http.setfilehandler(function(field, chunk, eof)
			if too_big or not field or field.name ~= "file" then
				return
			end
			if chunk and #chunk > 0 then
				total = total + #chunk
				if total > max_size then
					too_big = true
					if fd then
						fd:close()
						fd = nil
					end
					os.remove(tmp)
					return
				end
			end
			if not fd then
				fd = io.open(tmp, "wb")
			end
			if fd then
				got = true
				if chunk and #chunk > 0 then
					fd:write(chunk)
				end
				if eof then
					fd:close()
					fd = nil
				end
			end
		end)

		if fd then
			fd:close()
			fd = nil
		end

		if too_big then
			result = { ok = false, message = "Uploaded file too large (max 128 MB)" }
		elseif not got then
			result = { ok = false, message = "No uploaded file" }
		else
			result = common.action_core_upload(tmp)
		end
	elseif name == "domain_switch" then
		result = common.action_domain_switch(p)
	elseif name == "dns_sync" then
		result = common.action_dns_sync(p)
	elseif name == "tunnel_create" then
		result = common.action_tunnel_create(p)
	elseif name == "test_ingress" then
		result = common.action_test_ingress(p)
	elseif name == "ingress_dns" then
		result = common.action_ingress_dns()
	elseif name == "site_stats" then
		result = common.action_site_stats()
	elseif name == "core_check" then
		result = common.action_core_check()
	elseif name == "core_install" then
		result = common.action_core_install(p)
	elseif name == "core_status" then
		result = common.action_core_status(p)
	elseif name == "login_start" then
		result = common.action_login_start(p)
	elseif name == "login_status" then
		result = common.action_login_status(p)
	elseif name == "service" then
		result = common.action_service(p)
	elseif name == "service_enable" then
		result = common.action_service_enable(p)
	elseif name == "get_log" then
		result = common.action_get_log(p)
	elseif name == "clear_log" then
		result = common.action_clear_log(p)
	else
		result = { ok = false, message = "Unknown action" }
	end

	http.prepare_content("application/json")
	http.write(jsonc.stringify(result))
end
