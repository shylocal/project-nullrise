--!strict
-- Studio command-bar tool that bakes src/shared/weapons/AnimationManifest.lua
-- from the animations themselves (lengths and HitStart/HitStop marker times),
-- so AnimationContracts can check weapon move timing against them.
--
-- How to run it (Roblox Studio, place open, Rojo synced, NOT in a play test):
--   1. View > Command Bar.
--   2. Run: require(game.TestService.tools.BakeAnimationManifest).Run()
--   3. The generated module source is printed to the Output window and written
--      to the Source of ServerStorage.AnimationManifest_Generated (a
--      ModuleScript the tool creates or overwrites).
--   4. Open ServerStorage.AnimationManifest_Generated, copy its whole source and
--      paste it over src/shared/weapons/AnimationManifest.lua in the repository
--      (Rojo syncs files to Studio, not back), then delete the generated
--      ModuleScript from ServerStorage.
--   5. Re-run the TestEZ suite: the Catalog applies the manifest when it loads,
--      so a timing mismatch fails every require of the Catalog with the
--      offending move listed.
-- Animations that fail to load (for example ones the place's owner cannot
-- access) are skipped with a warning and stay unchecked.
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local OUTPUT_NAME = "AnimationManifest_Generated"
local MARKERS = { "HitStart", "HitStop" }

export type Entry = { Length: number, Markers: { [string]: number } }
export type Manifest = { [string]: Entry }

local BakeAnimationManifest = {}

local function add_animation(ids: { string }, seen: { [string]: boolean }, animation: any)
	if type(animation) == "table" and type(animation.Id) == "string" and not seen[animation.Id] then
		seen[animation.Id] = true
		table.insert(ids, animation.Id)
	end
end

-- Every distinct animation id used by the definitions (roles and moves), sorted.
function BakeAnimationManifest.collect_ids(definitions: { any }): { string }
	local ids, seen = {}, {}
	for _, definition in ipairs(definitions) do
		if type(definition.Animations) == "table" then
			for _, animation in pairs(definition.Animations) do
				add_animation(ids, seen, animation)
			end
		end
		if type(definition.Moves) == "table" then
			for _, move in pairs(definition.Moves) do
				add_animation(ids, seen, type(move) == "table" and move.Animation)
			end
		end
	end
	table.sort(ids)
	return ids
end

-- Length is the last keyframe's Time; each marker is its earliest keyframe Time.
function BakeAnimationManifest.bake(sequence: KeyframeSequence): Entry
	local length = 0
	local markers: { [string]: number } = {}
	for _, keyframe in ipairs(sequence:GetKeyframes()) do
		if not keyframe:IsA("Keyframe") then
			continue
		end
		length = math.max(length, keyframe.Time)
		for _, marker in ipairs(keyframe:GetMarkers()) do
			if table.find(MARKERS, marker.Name) then
				local previous = markers[marker.Name]
				if previous == nil or keyframe.Time < previous then
					markers[marker.Name] = keyframe.Time
				end
			end
		end
	end
	return { Length = length, Markers = markers }
end

-- Module source for AnimationManifest.lua, entries sorted by id.
function BakeAnimationManifest.render(manifest: Manifest): string
	local ids = {}
	for id in pairs(manifest) do
		table.insert(ids, id)
	end
	table.sort(ids)

	local lines = {
		"--!strict",
		"-- Baked animation data keyed by asset id, checked against weapon moves by",
		"-- AnimationContracts when the Catalog loads. Generated in Studio by",
		"-- tests/tools/BakeAnimationManifest (see that file for how to run it); paste its",
		"-- output over this file. Ids with no entry are not checked.",
		"-- Format: { [\"rbxassetid://N\"] = { Length = number, Markers = { HitStart = number?, HitStop = number? } } }",
		"return {",
	}
	for _, id in ipairs(ids) do
		local entry = manifest[id]
		local markers = {}
		for _, name in ipairs(MARKERS) do
			local time = entry.Markers[name]
			if time ~= nil then
				table.insert(markers, ("%s = %s"):format(name, tostring(time)))
			end
		end
		local marker_list = if #markers > 0 then "{ " .. table.concat(markers, ", ") .. " }" else "{}"
		table.insert(
			lines,
			("\t[%q] = { Length = %s, Markers = %s },"):format(id, tostring(entry.Length), marker_list)
		)
	end
	table.insert(lines, "}")
	return table.concat(lines, "\n") .. "\n"
end

-- Bakes every Catalog animation, prints the module source, writes it to
-- ServerStorage.AnimationManifest_Generated and returns it.
function BakeAnimationManifest.Run(): string
	assert(RunService:IsStudio(), "BakeAnimationManifest runs only in Roblox Studio")
	if RunService:IsRunning() then
		warn("[BakeAnimationManifest] Run this from the command bar in Edit mode; play-test changes are discarded")
	end

	local Catalog = (require :: any)(ReplicatedStorage.shared.weapons.Catalog)
	local manifest: Manifest = {}
	local baked, failed = 0, 0
	for _, id in ipairs(BakeAnimationManifest.collect_ids(Catalog.All())) do
		local ok, result = pcall(function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync(id)
		end)
		if ok and typeof(result) == "Instance" and result:IsA("KeyframeSequence") then
			manifest[id] = BakeAnimationManifest.bake(result)
			baked += 1
		else
			failed += 1
			warn(("[BakeAnimationManifest] %s could not be loaded and stays unchecked: %s"):format(id, tostring(result)))
		end
	end

	local source = BakeAnimationManifest.render(manifest)
	local output = ServerStorage:FindFirstChild(OUTPUT_NAME)
	if output == nil or not output:IsA("ModuleScript") then
		if output then
			output:Destroy()
		end
		output = Instance.new("ModuleScript")
		output.Name = OUTPUT_NAME
		output.Parent = ServerStorage
	end
	-- Script.Source is writable from the command bar (plugin security).
	(output :: any).Source = source

	print(source)
	print(
		("[BakeAnimationManifest] Baked %d animation(s), %d failed. Copy ServerStorage.%s over src/shared/weapons/AnimationManifest.lua."):format(
			baked,
			failed,
			OUTPUT_NAME
		)
	)
	return source
end

return table.freeze(BakeAnimationManifest)
