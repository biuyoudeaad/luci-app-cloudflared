local M = {}

local function read_pairs(path)
	local result = {}
	local f = io.open(path, "r")
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

local function db_path()
	return os.getenv("MOCK_DB") or "/tmp/cf-mock-db"
end

local function type_path()
	return os.getenv("MOCK_TYPE") or "/tmp/cf-mock-type"
end

function M.cursor()
	local cursor = {}

	function cursor:get(config, section, option)
		local db = read_pairs(db_path())
		local key = config .. "." .. section
		if option then
			key = key .. "." .. option
		end
		if option then
			return db[key]
		end
		return read_pairs(type_path())[key]
	end

	function cursor:get_all(config, section)
		local db = read_pairs(db_path())
		local prefix = config .. "." .. section .. "."
		local result = { [".name"] = section, [".type"] = self:get(config, section) }
		for key, value in pairs(db) do
			if key:sub(1, #prefix) == prefix then
				result[key:sub(#prefix + 1)] = value
			end
		end
		return result
	end

	function cursor:foreach(config, section_type, callback)
		local types = read_pairs(type_path())
		local sections = {}
		for key, value in pairs(types) do
			local conf, section = key:match("^([^.]+)%.(.+)$")
			if conf == config and value == section_type then
				sections[#sections + 1] = section
			end
		end
		table.sort(sections)
		for _, section in ipairs(sections) do
			callback(self:get_all(config, section))
		end
	end

	return cursor
end

return M
