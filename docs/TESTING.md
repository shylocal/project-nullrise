# Running Tests

The project uses TestEZ for small, deterministic Luau tests. Rojo maps the contents of the `tests/` directory directly into Roblox `TestService` (so there is no `TestService.tests` parent folder). Tests are not run automatically during game startup.

## Install TestEZ once

The project avoids Wally and keeps third-party Roblox modules in the existing Roblox-managed `ReplicatedStorage.packages` folder.

1. Download the source for [Roblox/TestEZ v0.4.2](https://github.com/Roblox/testez/releases/tag/v0.4.2).
2. Add the release's `src` tree as a package named `TestEZ` under `ReplicatedStorage.packages`, using the same Roblox package workflow as the project's other packages. The root module must be `TestEZ` (from `src/init.lua`), with its child modules and `Reporters` folder preserved.
3. Confirm that this path exists in Studio: `ReplicatedStorage.packages.TestEZ`.

TestEZ's upstream repository is archived, so keep the dependency pinned to the selected release rather than tracking a moving branch. See the [upstream repository](https://github.com/Roblox/testez) for source and licensing details.

## Run the suite in Studio

1. From the project root, start Rojo with `rojo serve`.
2. Open the place in Roblox Studio and connect the Rojo plugin to the running server so the current source is synced.
3. Start a local test session with **Test > Play** (or **Play**).
4. Open the Studio Command Bar and set its execution context to **Server**.
5. Run:

```lua
require(game:GetService("TestService").RunTests).Run()
```

TestEZ's text reporter writes the test results to the Output window. The runner returns TestEZ's results object. It also checks `RunService:IsStudio()`, so it cannot be invoked in a published server.

## Add a test

Create a ModuleScript file ending in `.spec.lua` under `tests/specs`. Rojo maps the contents of `tests/` into `TestService`, placing the specs folder at `TestService.specs`. TestEZ recursively discovers spec ModuleScripts under that folder.

A spec module returns a function and uses TestEZ's `describe`, `it`, and `expect` functions:

```lua
return function()
	describe("Example", function()
		it("checks a behavior", function()
			expect(2 + 2).to.equal(4)
		end)
	end)
end
```

Keep unit tests deterministic and self-contained. Prefer testing pure functions and validation rules first. Tests that create Instances, connect signals, or mutate services should clean up what they create and avoid firing live remotes or depending on the current map.

## Current coverage

The suite includes:

- `Vector.spec.lua`: verifies horizontal vector flattening.
- `ParkourMath.spec.lua`: checks smoothstep clamping/monotonicity, vault arc endpoints/peak/range, and crouch-weight bounds/fades.
- `ParkourConfig.spec.lua`: checks parkour distance, height, timing, and arc invariants without pinning every tuning value.
- `InputController.spec.lua`: exercises action begin/end de-duplication and held-action release behavior using isolated signals.
- `MovementController.spec.lua`: creates a temporary Model/Humanoid to verify sprint transitions, independent blockers, speed overrides, validation, and change events.
- `WeaponCatalog.spec.lua` and `WeaponDefinitions.spec.lua`: validate catalog lookups and the built-in weapon/attack/animation data shapes.
- `Protocol.spec.lua`: checks shared action and remote identifiers for valid, unique strings.
- `CombatValidation.spec.lua`: checks rejection of malformed target, segment, and non-finite position inputs.
- `InventoryValidation.spec.lua`: checks rejection of invalid slot values and unknown weapon IDs.
- `RuntimeContracts.spec.lua`: smoke-checks configured remotes, required packages, weapon models, client controller constructors, and server-module exports in the Studio place.


The suite currently defines **40 TestEZ cases** across these specs. This is a starting regression net, not exhaustive gameplay coverage; in particular, it does not simulate real parkour raycasts against the map, animation playback, or multiplayer combat timing.

The behavior tests use isolated fixtures and avoid invoking live remotes or depending on map geometry. They are useful regression checks, but they do not replace Studio playtesting of real movement physics, parkour detection against authored map parts, animation asset availability, or multiplayer combat.

The repository changes were statically inspected only. Run the suite in Studio and review the Output before treating these new specs as passing in your environment.
