--!strict
-- Constructor dependency checks. Every dependency a constructor lists is
-- required; there are no defaulted dependencies.
local Deps = {}

function Deps.check(deps: any, owner: string, required: { string }): ()
	if type(deps) ~= "table" then
		error(("%s.new: deps must be a table, got %s"):format(owner, typeof(deps)), 3)
	end

	for _, key in required do
		if deps[key] == nil then
			error(("%s.new: missing dependency '%s'"):format(owner, key), 3)
		end
	end
end

return table.freeze(Deps)
