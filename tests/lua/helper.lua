local M = {}

function M.setup(root, testdir, tmp)
	package.path = root .. "/root/usr/lib/lua/?.lua;" ..
		testdir .. "/lua/stubs/?.lua;" ..
		testdir .. "/lua/stubs/?/init.lua;" ..
		package.path

	local common = require "luci.cloudflared.common"
	common.CTL = root .. "/root/usr/bin/cloudflared-ctl"
	common.STATE_DIR = tmp .. "/state"

	M.root = root
	M.testdir = testdir
	M.tmp = tmp
	M.common = common
	M.db = os.getenv("MOCK_DB") or (tmp .. "/db")
	M.types = os.getenv("MOCK_TYPE") or (tmp .. "/type")
	M.base = tmp .. "/base"
	M.STATE_DIR = tmp .. "/state"

	os.execute("mkdir -p '" .. M.base .. "/t1' '" .. M.base .. "/t2' '" .. M.STATE_DIR .. "'")

	local function write(path, data)
		local f = assert(io.open(path, "w"))
		f:write(data)
		f:close()
	end

	write(M.base .. "/t1/tid1.json", '{"TunnelID":"tid1","TunnelSecret":"s1","AccountTag":"a"}\n')
	write(M.base .. "/t2/tid2.json", '{"TunnelID":"tid2","TunnelSecret":"s2","AccountTag":"a"}\n')
	write(M.base .. "/cert.pem", "BEGIN CERTIFICATE\nx\n")

	write(M.types, table.concat({
		"cloudflared.main=main",
		"cloudflared.t1=tunnel",
		"cloudflared.t2=tunnel",
		"cloudflared.r1=ingress",
		"cloudflared.r2=ingress",
	}, "\n") .. "\n")

	write(M.db, table.concat({
		"cloudflared.main.base_path=" .. M.base,
		"cloudflared.main.api_token=token",
		"cloudflared.main.allow_dns_delete=1",
		"cloudflared.main.cert_path=" .. M.base .. "/cert.pem",
		"cloudflared.t1.name=t1",
		"cloudflared.t1.enabled=1",
		"cloudflared.t1.domain=example.com",
		"cloudflared.t1.applied_domain=example.com",
		"cloudflared.t1.tunnel_id=tid1",
		"cloudflared.t1.data_dir=" .. M.base .. "/t1",
		"cloudflared.t1.credentials_file=" .. M.base .. "/t1/tid1.json",
		"cloudflared.t2.name=t2",
		"cloudflared.t2.enabled=1",
		"cloudflared.t2.domain=example.com",
		"cloudflared.t2.applied_domain=example.com",
		"cloudflared.t2.tunnel_id=tid2",
		"cloudflared.t2.data_dir=" .. M.base .. "/t2",
		"cloudflared.t2.credentials_file=" .. M.base .. "/t2/tid2.json",
		"cloudflared.r1.tunnel=t1",
		"cloudflared.r1.hostname=a.example.com",
		"cloudflared.r1.service=http://10.0.0.1:80",
		"cloudflared.r2.tunnel=t2",
		"cloudflared.r2.hostname=b.example.com",
		"cloudflared.r2.service=http://10.0.0.2:80",
	}, "\n") .. "\n")

	os.execute("chmod +x '" .. testdir .. "/mock/uci'")

	return M
end

function M.read_db()
	local result = {}
	local f = io.open(M.db, "r")
	if not f then
		return result
	end
	for line in f:lines() do
		local key, value = line:match("^([^=]+)=(.*)$")
		if key then
			result[key] = value
		end
	end
	f:close()
	return result
end

function M.write_db(values)
	local lines = {}
	local keys = {}
	for key in pairs(values) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		lines[#lines + 1] = key .. "=" .. values[key]
	end
	local f = assert(io.open(M.db, "w"))
	f:write(table.concat(lines, "\n") .. "\n")
	f:close()
end

function M.set(key, value)
	local values = M.read_db()
	values[key] = value
	M.write_db(values)
end

function M.assert(condition, message)
	if not condition then
		error("FAIL: " .. message, 2)
	end
end

function M.contains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

return M
