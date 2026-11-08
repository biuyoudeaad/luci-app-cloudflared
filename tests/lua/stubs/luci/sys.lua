local M = {}

function M.exec(command)
	local pipe = io.popen(command)
	if not pipe then
		return ""
	end
	local data = pipe:read("*a") or ""
	pipe:close()
	return data
end

function M.call(command)
	return os.execute(command)
end

return M
