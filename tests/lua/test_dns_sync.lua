local root = os.getenv("ROOT")
local testdir = os.getenv("TESTDIR")
local tmp = os.getenv("TMP")

package.path = testdir .. "/lua/?.lua;" .. package.path

local helper = require "helper"
helper.setup(root, testdir, tmp)

local common = helper.common
local original_run = common.run
local state = "created"

common.run = function()
	return "status=" .. state .. "\nhost=a.example.com\nmessage=" .. state .. "\n"
end

local result = common.action_dns_sync({ section = "t1" })
helper.assert(result.ok, "created result must be ok")
helper.assert(result.total == 1, "only t1 hosts must be counted")
helper.assert(result.created_count == 1, "one host must be created")
helper.assert(result.exists_count == 0 and result.failed_count == 0, "no other categories")
helper.assert(result.created[1] == "a.example.com", "created host list mismatch")

state = "exists"
result = common.action_dns_sync({ section = "t1" })
helper.assert(result.ok, "exists result must be ok")
helper.assert(result.created_count == 0, "no created hosts")
helper.assert(result.exists_count == 1, "one host must exist")
helper.assert(result.exists[1] == "a.example.com", "exists host list mismatch")

state = "failed"
result = common.action_dns_sync({ section = "t1" })
helper.assert(not result.ok, "failed result must not be ok")
helper.assert(result.failed_count == 1, "one host must fail")
helper.assert(result.failed[1] == "a.example.com", "failed host list mismatch")

common.run = original_run
print("lua dns sync classification test passed")
