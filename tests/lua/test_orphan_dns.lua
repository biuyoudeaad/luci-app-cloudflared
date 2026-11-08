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
		["old.example.com"] = { id = "2", zone_id = "z" },
	}
end

common.cf_api = function(method, path)
	deleted[#deleted + 1] = method .. " " .. path
	return { success = true }
end

local result = common.delete_orphan_dns("t1")
helper.assert(result.ok, "delete_orphan_dns should succeed")
helper.assert(result.deleted == 1, "should delete exactly one record")
helper.assert(#deleted == 1, "should issue exactly one DELETE call")
helper.assert(deleted[1] == "DELETE /zones/z/dns_records/2",
	"unexpected DELETE call: " .. tostring(deleted[1]))

helper.set("cloudflared.main.allow_dns_delete", "0")
deleted = {}
result = common.delete_orphan_dns("t1")
helper.assert(result.deleted == 0, "deletion must be disabled")
helper.assert(#deleted == 0, "no DELETE call when disabled")

print("lua orphan dns test passed")
