local root = os.getenv("ROOT")
local testdir = os.getenv("TESTDIR")
local tmp = os.getenv("TMP")
package.path = testdir .. "/lua/?.lua;" .. package.path
local helper = require "helper"
helper.setup(root, testdir, tmp)
local common = helper.common
local rule = { hostname = "site.example.com", service = "http://192.0.2.1:80" }
local tunnel = { enabled = true, tunnel_id = "tid1", domain = "example.com" }
local function check(expected, dns, running)
	helper.assert(common.site_state(rule, tunnel, dns, running) == expected, expected .. " classification")
end
check("running", "synced", true)
check("pending", "pending", true)
check("abnormal", "unknown", true)
check("abnormal", "synced", false)
rule.service = "not-a-service"
check("abnormal", "synced", true)
rule.enabled = "0"
check("disabled", "unknown", false)
rule.enabled = "1"
rule.service = "unix:/run/example.sock"
check("running", "synced", true)
rule.service = "http_status:404"
check("running", "synced", true)
rule.service = "http_status:700"
check("abnormal", "synced", true)
rule.service = "http://192.0.2.1:70000"
check("abnormal", "synced", true)
tunnel.enabled = false
check("disabled", "synced", true)
tunnel = nil
check("abnormal", "synced", true)

local sys = require "luci.sys"
local jsonc = require "luci.jsonc"
local original_parse, original_exec = jsonc.parse, sys.exec
sys.exec = function() return "service-test" end
jsonc.parse = function(value)
	if value == "service-test" then
		return { cloudflared = { instances = { tunnel_t1 = { running = true }, tunnel_t2 = { running = false } } } }
	end
	return original_parse(value)
end
local original_dns = common.action_ingress_dns
common.action_ingress_dns = function()
	return { ok = true, status = { r1 = "synced", r2 = "pending" } }
end
local result = common.action_site_stats()
helper.assert(result.counts.total == 2 and result.counts.running == 1 and result.counts.abnormal == 1,
	"site must use its own tunnel process, not any running tunnel")
jsonc.parse = function()
	return { cloudflared = { instances = { tunnel_t1 = { running = true }, tunnel_t2 = { running = true } } } }
end
result = common.action_site_stats()
helper.assert(result.counts.running == 1 and result.counts.pending == 1, "missing CNAME is pending sync")
helper.set("cloudflared.t2.enabled", "0")
result = common.action_site_stats()
helper.assert(result.counts.disabled == 1, "disabled tunnel disables its sites")
helper.set("cloudflared.r1.enabled", "0")
result = common.action_site_stats()
helper.assert(result.counts.disabled == 2, "disabled rules take precedence")
local counts = result.counts
helper.assert(counts.total == counts.running + counts.pending + counts.abnormal + counts.disabled,
	"all categories must sum to total")
jsonc.parse, sys.exec = original_parse, original_exec
common.action_ingress_dns = original_dns
local original_cached = common.cached_tunnel_dns
helper.set("cloudflared.r1.enabled", "1")
helper.set("cloudflared.r2.hostname", "a.example.com")
common.cached_tunnel_dns = function(section)
	return section == "t1" and { ["a.example.com"] = true } or {}, true
end
result = common.action_ingress_dns()
helper.assert(result.status.r1 == "synced" and result.status.r2 == "pending",
	"DNS record for the same hostname on another tunnel must not count as synced")
common.cached_tunnel_dns = function() return {}, false end
result = common.action_ingress_dns()
helper.assert(result.status.r1 == "unknown", "failed lookup is unknown, not pending")
common.cached_tunnel_dns = original_cached

-- Failed DNS requests must not become successful empty caches (pending sync).
local fs = require "nixio.fs"
fs.stat = function() return nil end
local original_writefile = fs.writefile
fs.writefile = function() error("must not cache failed DNS request") end
common.fetch_tunnel_dns = function() return {}, false end
local _, success = common.cached_tunnel_dns("failure", "token", "tid", "example.com")
helper.assert(success == false, "DNS failure must remain distinguishable from missing CNAME")
fs.writefile = original_writefile
print("lua site statistics test passed")
