local root = os.getenv("ROOT")
local testdir = os.getenv("TESTDIR")
local tmp = os.getenv("TMP")

package.path = testdir .. "/lua/?.lua;" .. package.path

local helper = require "helper"
helper.setup(root, testdir, tmp)

local common = helper.common

local before = common.snapshot_tunnels()
helper.assert(before.t1, "expected tunnel t1")
helper.assert(before.t2, "expected tunnel t2")
helper.assert(before.t1 ~= before.t2, "tunnel signatures must differ")

helper.assert(common.gen_config("t1"), "initial gen_config failed")
local ok, changed = common.regen_sections({ "t1" })
helper.assert(ok, "regen_sections failed")
helper.assert(changed == false, "unexpected config change without edits")

helper.set("cloudflared.t1.domain", "new.com")
helper.set("cloudflared.t1.applied_domain", "new.com")
helper.set("cloudflared.r1.hostname", "a.new.com")

local after = common.snapshot_tunnels()
local changed_sections, added, removed = common.diff_snapshots(before, after)

helper.assert(helper.contains(changed_sections, "t1"), "t1 should be detected as changed")
helper.assert(not helper.contains(changed_sections, "t2"), "t2 must not be marked changed")
helper.assert(#added == 0, "no tunnel should be added")
helper.assert(#removed == 0, "no tunnel should be removed")

local ok2, cfg_changed = common.regen_sections({ "t1" })
helper.assert(ok2, "regen_sections failed after edit")
helper.assert(cfg_changed == true, "config content should change after edit")

helper.assert(common.is_safe_path("/opt/cloudflare/cert.pem"), "absolute path should be safe")
helper.assert(common.is_safe_path("/etc/cloudflared/cert.pem"), "new data path should be safe")
helper.assert(not common.is_safe_path("../etc/passwd"), "traversal path must be rejected")

-- New persistent layout: data_path wins over legacy base_path.
local data = tmp .. "/data"
helper.set("cloudflared.main.data_path", data)
helper.assert(common.data_path() == data, "data_path should be used")
helper.assert(common.tunnel_dir("t3") == data .. "/tunnels/t3", "tunnel dir should follow data_path")
helper.assert(common.core_target() == "/opt/cloudflared/bin/cloudflared", "core target should use new core dir")
helper.set("cloudflared.main.cert_path", "")
helper.assert(common.resolve_cert("t3") == data .. "/cert.pem", "cert should default under data_path")

print("lua snapshot/change-detection test passed")
