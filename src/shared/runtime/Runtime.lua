--!strict
-- Ordered service composition. Factories run in Add order (each may `get` a
-- service built before it), then every built service's optional Start runs in
-- the same order. Teardown is always the reverse of construction, so a
-- consumer is destroyed before the services it depends on.
export type Service = {
	Destroy: (self: any) -> (),
	Start: ((self: any) -> ())?,
}
-- Factories return a Service; the shape is checked when Start builds it, so
-- class types with typed `self` methods need no casts at the call site.
export type Factory = (get: (name: string) -> any) -> any

type Entry = {
	Name: string,
	Factory: Factory,
}

type RuntimeFields = {
	Name: string,
	_entries: { Entry },
	_names: { [string]: boolean },
	_built: { { Name: string, Service: Service } },
	_services: { [string]: Service },
	_started: boolean,
	_destroyed: boolean,
}

local Runtime = {}
Runtime.__index = Runtime

export type Runtime = typeof(setmetatable({} :: RuntimeFields, Runtime))

function Runtime.new(name: string): Runtime
	assert(type(name) == "string" and name ~= "", "Runtime.new: name must be a non-empty string")

	local self: RuntimeFields = {
		Name = name,
		_entries = {},
		_names = {},
		_built = {},
		_services = {},
		_started = false,
		_destroyed = false,
	}

	return setmetatable(self, Runtime)
end

function Runtime.Add(self: Runtime, name: string, factory: Factory): ()
	if self._started or self._destroyed then
		error(("%s: cannot add %s after Start"):format(self.Name, tostring(name)), 2)
	end
	if type(name) ~= "string" or name == "" then
		error(("%s: service name must be a non-empty string"):format(self.Name), 2)
	end
	if self._names[name] then
		error(("%s: duplicate service %s"):format(self.Name, name), 2)
	end
	if type(factory) ~= "function" then
		error(("%s: factory for %s must be a function"):format(self.Name, name), 2)
	end

	self._names[name] = true
	table.insert(self._entries, { Name = name, Factory = factory })
end

local function destroy_built(self: Runtime)
	local built = self._built
	for index = #built, 1, -1 do
		local record = built[index]
		local ok, err = pcall(function()
			record.Service:Destroy()
		end)
		if not ok then
			warn(("[%s] failed to destroy %s: %s"):format(self.Name, record.Name, tostring(err)))
		end
	end

	table.clear(built)
	table.clear(self._services)
end

function Runtime.Start(self: Runtime): ()
	if self._started or self._destroyed then
		error(("%s: Start called twice"):format(self.Name), 2)
	end
	self._started = true

	local current = "?"

	local function get(name: string): any
		local service = self._services[name]
		if service == nil then
			error(("%s requested %s, which is not built yet"):format(current, tostring(name)), 2)
		end
		return service
	end

	local ok, err = pcall(function()
		for _, entry in self._entries do
			current = entry.Name
			local service = entry.Factory(get)
			if type(service) ~= "table" or type((service :: any).Destroy) ~= "function" then
				error("factory did not return a service with Destroy", 0)
			end
			self._services[entry.Name] = service
			table.insert(self._built, { Name = entry.Name, Service = service })
		end

		for _, record in self._built do
			current = record.Name
			local start = record.Service.Start
			if start then
				start(record.Service)
			end
		end
	end)

	if not ok then
		destroy_built(self)
		self._destroyed = true
		error(("%s: failed to start %s: %s"):format(self.Name, current, tostring(err)), 0)
	end
end

function Runtime.Get(self: Runtime, name: string): any
	local service = self._services[name]
	if service == nil then
		error(("%s: unknown service %s"):format(self.Name, tostring(name)), 2)
	end
	return service
end

function Runtime.Destroy(self: Runtime): ()
	if self._destroyed then
		return
	end
	self._destroyed = true
	destroy_built(self)
end

return Runtime
