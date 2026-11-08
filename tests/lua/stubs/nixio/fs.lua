local M = {}

function M.access(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

function M.readfile(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

function M.writefile(path, data)
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(data)
	f:close()
	return true
end

function M.mkdirr(path)
	os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
	return true
end

function M.dir()
	return nil
end

function M.remove(path)
	os.remove(path)
	return true
end

return M
