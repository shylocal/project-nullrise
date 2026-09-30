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

## Profiling parkour queries in Studio

Query profiling is opt-in and disabled by default. During a local play session, switch the Command Bar execution context to **Client** and run:

```lua
local character = game:GetService("Players").LocalPlayer.Character
character:SetAttribute("ParkourQueryMetrics", true)
```

While hanging from tagged ledges, press **W** to attempt a mantle and **S** to search for a lower ledge. Each search prints one `[ParkourMetrics]` line to the client Output. It reports elapsed search time, raycasts, overlap queries, tagged guides enumerated/visited, guides inside/outside the conservative search bounds, sampled guide columns, `Model:GetBoundingBox()` calls (`ModelBoundsQueries`), and guide-top/stack raycasts. Metrics reset for each measured search. Disable profiling with:

```lua
character:SetAttribute("ParkourQueryMetrics", false)
```

For a useful baseline, test the same map location and traversal direction several times, and retain the Output lines. Timing varies with Studio load; compare query counts first and treat milliseconds as a rough indicator. These counters measure query workload, not frame time or client-wide performance.

## Parkour lifecycle Studio checks

These checks complement the isolated lifecycle specs because they exercise Roblox character physics and the actual traversal queries. Run them in a local Studio session with the Rojo-synced source:

- **Release while hanging:** grab a tagged ledge, then release Jump. Confirm the character drops normally, AutoRotate and PlatformStand return to their prior values, and sprint works again.
- **Interrupt a mantle:** start a mantle and reset the character before it completes. Confirm the old character does not remain movement-locked and the respawned character can move, sprint, and jump.
- **Release Jump during a scripted vault:** begin a sprint vault and release Jump mid-flight. Confirm the vault completes or exits safely and jumping remains available afterward.
- **Interrupt a vault:** reset the character during a scripted vault and during a physics top-hop. Confirm no stale traversal callback changes the replacement character and the next character can jump and sprint.
- **Focus loss:** while Jump is held during a hang or vault, switch focus away from Studio and back. Confirm held-action reconciliation releases the appropriate lock without leaving Humanoid state disabled.

Record any failures with the Output log and the exact traversal/interruption step. Do not interpret a passing TestEZ run as proof that these physics-dependent scenarios passed.

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
- `ParkourLifecycle.spec.lua`: verifies allowed traversal state transitions, hanging and mantle restoration, vault Jumping snapshot ownership after Jump release, and idempotent controller teardown.
- `ParkourMetrics.spec.lua`: verifies opt-in query counters, defensive snapshots, and reset behavior.

The suite currently defines **47 TestEZ cases** across these specs. This is a starting regression net, not exhaustive gameplay coverage; in particular, it does not simulate real parkour raycasts against the map, animation playback, or multiplayer combat timing.

The user confirmed **47 passed, 0 failed, 0 skipped** in Studio before the mantle bounds-filter optimization. Subsequent Studio metrics confirmed the expected reduction: mantle sampling fell from 210 to 126 columns and raycasts from 387–388 to 261–262; lower-ledge sampling remained at 84 columns with 176–177 raycasts. Mantle timings were 0.90–0.93 ms in the supplied post-change samples versus 1.08–1.83 ms in the baseline, but the small sample is not enough to treat timing as a stable benchmark. The new `ModelBoundsQueries` counter was added after those measurements; re-sync and rerun the suite and profiling session to capture it and confirm the current revision. Query profiling instructions are in the section above.

The behavior tests use isolated fixtures and avoid invoking live remotes or depending on map geometry. They are useful regression checks, but they do not replace Studio playtesting of real movement physics, parkour detection against authored map parts, animation asset availability, or multiplayer combat.
