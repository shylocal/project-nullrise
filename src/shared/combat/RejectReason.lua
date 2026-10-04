--!strict
-- Reason codes for dropped or rejected client requests. Each name maps to
-- itself so values can be compared, logged and used as telemetry keys.
export type Reason = string

local REASONS = {
	"BadPayload",
	"NotActive",
	"Expired",
	"AttackerInvalid",
	"TargetInvalid",
	"WieldMismatch",
	"NoHitpoint",
	"Reach",
	"OffBody",
	"HitpointOffset",
	"Facing",
	"NoLOS",
	"Duplicate",
	"RejectLimit",
	"EarlyHitStart",
	"LateHitStart",
	"RateLimited",
	"UnknownAction",
	"Blocked",
	"HorizontalSpeed",
	"VerticalSpeed",
	"TeleportDistance",
}

local KNOWN: { [string]: boolean } = {}
for _, name in REASONS do
	KNOWN[name] = true
end

local RejectReason = {
	BadPayload = "BadPayload",
	NotActive = "NotActive",
	Expired = "Expired",
	AttackerInvalid = "AttackerInvalid",
	TargetInvalid = "TargetInvalid",
	WieldMismatch = "WieldMismatch",
	NoHitpoint = "NoHitpoint",
	Reach = "Reach",
	OffBody = "OffBody",
	HitpointOffset = "HitpointOffset",
	Facing = "Facing",
	NoLOS = "NoLOS",
	Duplicate = "Duplicate",
	RejectLimit = "RejectLimit",
	EarlyHitStart = "EarlyHitStart",
	LateHitStart = "LateHitStart",
	RateLimited = "RateLimited",
	UnknownAction = "UnknownAction",
	Blocked = "Blocked",
	HorizontalSpeed = "HorizontalSpeed",
	VerticalSpeed = "VerticalSpeed",
	TeleportDistance = "TeleportDistance",
}

-- The literal table above and REASONS must list the same names.
for _, name in REASONS do
	assert((RejectReason :: any)[name] == name, ("RejectReason.%s is missing"):format(name))
end
for name: string, value: any in pairs(RejectReason :: { [string]: any }) do
	assert(KNOWN[name] and value == name, ("RejectReason.%s is not listed"):format(name))
end

local function is(value: any): boolean
	return type(value) == "string" and KNOWN[value] == true
end

local exported = table.clone(RejectReason) :: any
exported.is = is
exported.All = table.freeze(table.clone(REASONS))

return table.freeze(exported) :: typeof(RejectReason) & {
	is: (value: any) -> boolean,
	All: { string },
}
