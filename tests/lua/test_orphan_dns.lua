local root = os.getenv("ROOT")
local testdir = os.getenv("TESTDIR")
local tmp = os.getenv("TMP")

package.path = testdir .. "/lua/?.lua;" .. package.path

local helper = require "helper"
helper.setup(root, testdir, tmp)

local common = helper.common
local deleted = {}

common.fetch_tunnel_dns = function()
	return {
		["a.example.com"] = { id = "1", zone_id = "z" },
		["name.example.com"] = { id = "3", zone_id = "z" },
		["uuid.example.com"] = { id = "4", zone_id = "z" },
		["old.example.com"] = { id = "2", zone_id = "z" },
	}, true
end

common.cf_api = function(method, path)
	deleted[#deleted + 1] = method .. " " .. path
	return { success = true }
end

local result = common.delete_orphan_dns("t1")
helper.assert(result.ok, "delete_orphan_dns should succeed")
helper.assert(result.deleted == 3, "should delete exactly three orphan records")
helper.assert(#deleted == 3, "should issue exactly three DELETE calls")

-- Ingress rules may reference a tunnel by section name, display name or UUID.
-- All forms must belong to the same tunnel for orphan detection.
helper.set("cloudflared.r1.hostname", "a.example.com")
helper.set("cloudflared.r1.tunnel", "t1")
helper.set("cloudflared.r2.hostname", "name.example.com")
helper.set("cloudflared.r2.tunnel", "t1")
helper.set("cloudflared.r3.tunnel", "tid1")
helper.set("cloudflared.r3.hostname", "uuid.example.com")
local f = io.open(helper.types, "a")
f:write("cloudflared.r3=ingress\n")
f:close()
deleted = {}
result = common.delete_orphan_dns("t1")
helper.assert(result.deleted == 1, "name and UUID references must not be orphaned")

helper.set("cloudflared.main.allow_dns_delete", "0")
deleted = {}
result = common.delete_orphan_dns("t1")
helper.assert(result.deleted == 0, "deletion must be disabled")
helper.assert(#deleted == 0, "no DELETE call when disabled")

-- Explicit tunnel deletion is independent of the automatic cleanup setting.
local uci = require "luci.model.uci"
local original_cursor = uci.cursor
uci.cursor = function()
	local cursor = original_cursor()
	function cursor:delete() return true end
	function cursor:commit() return true end
	return cursor
end
common.action_apply_tunnels = function() return { ok = true } end
deleted = {}
result = common.action_tunnel_delete({ section = "t1", delete_dns = "0" })
helper.assert(result.ok and #deleted == 0, "unchecked manual DNS deletion must not delete records")
deleted = {}
result = common.action_tunnel_delete({ section = "t1", delete_dns = "1" })
helper.assert(result.ok and result.dns_deleted == 4, "checked manual DNS deletion must work when automatic cleanup is disabled")
helper.assert(#deleted == 4, "manual DNS deletion should issue DELETE requests")
uci.cursor = original_cursor

print("lua orphan dns test passed")
