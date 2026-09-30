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
- **Confirmed by user:** death while hanging produced no errors; releasing Jump mid-vault allowed the vault to continue; focus loss and reacquisition worked as expected. Resetting during mantle, vault, and top-hop also produced no errors; confirm replacement-character movement/jump/sprint restoration explicitly.
- **Server combat lifecycle:** begin an attack, then kill/reset the attacker or replace its character before the hit window closes. Confirm later hit reports cause no damage. Repeat with a weapon swap and player removal; ensure no stale hitbox or attack state survives. The user confirmed **56 passed, 0 failed, 0 skipped** in Studio; the five `WeaponAttachment` warnings came from intentionally invalid fixtures and were expected. They subsequently confirmed the expanded **59 passed, 0 failed, 0 skipped** run. The user also confirmed weapon swapping works, character death during a swing produces no errors, and the system functions as expected inside Studio.

Record any failures with the Output log and the exact traversal/interruption step. Do not interpret a passing TestEZ run as proof that these physics-dependent scenarios passed.

## Input reconciliation Studio checks

These checks exercise the live input adapters and complement the isolated InputController.spec.lua tests:

- Hold a keyboard action such as **W** or **Left Shift**, then switch to touch input on a touchscreen device. Confirm the previous device's held action ends once and does not remain stuck.
- Switch between keyboard and mouse while holding a PC action. Confirm the action remains active because keyboard and mouse are treated as one device family.
- Hold **Left Shift** and press **Right Shift** while continuing to hold Left Shift; release Left Shift, then release Right Shift last. Confirm Sprint stays active through the first release and ends on the final Shift release. Repeat with the keys in reverse order. Roblox may suppress a modifier-key event or report the opposite Shift key. The PC adapter reconciles ordinary Shift releases against `UserInputService:GetKeysPressed()`; if an `InputEnded` key does not match the sole tracked Shift, it treats that as the release of the remaining stale Sprint source instead of trusting a contradictory key-state snapshot. Use the temporary `[ShiftTrace]` lines to verify event identity and state reconciliation. The monitor stops on Sprint release, focus loss, device-family reset, or destruction.
- Repeat a device switch while an action is held, then return to the original device. Confirm fresh input begins normally and focus-loss release still emits only one end transition.

The current source maps gamepad input types for stale-hold reconciliation, but does not define gamepad action bindings.

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
- `InputController.spec.lua`: exercises action begin/end de-duplication, focus release, source-aware holds, input-family changes, aliased keyboard controls, and PC Shift-release reconciliation using isolated signals.
- `MovementController.spec.lua`: creates a temporary Model/Humanoid to verify sprint transitions, independent blockers, speed overrides, validation, and change events.
- `WeaponCatalog.spec.lua` and `WeaponDefinitions.spec.lua`: validate catalog lookups and the built-in weapon/attack/animation data shapes.
- `WeaponAttachment.spec.lua`: verifies clone preparation, Motor6D binding, Hitpoint tagging, invalid-model cleanup, and safe handling of malformed wield mappings. Its invalid-model and malformed-entry cases intentionally print attachment warnings for their invalid fixtures; those warnings are expected.
- `Protocol.spec.lua`: checks shared action and remote identifiers for valid, unique strings.
- `CombatValidation.spec.lua`: checks rejection of malformed target, segment, and non-finite position inputs.
- `CombatService.spec.lua`: verifies active-hit cleanup on attacker death, character replacement, and expired windows; valid hit activation; and attack-state reset on weapon change and player removal. These tests use isolated service fixtures and do not fire live remotes.
- `AttackLifecycle.spec.lua`: verifies callback ownership accepts the current attack lifecycle and rejects replaced or stale lifecycle generations.
- `InventoryValidation.spec.lua`: checks finite positive-integer slot validation, accepts slots beyond current keyboard bindings, rejects unknown weapon IDs, and verifies replicated slot snapshots are detached from server-owned state.
- `RuntimeContracts.spec.lua`: smoke-checks configured remotes, required packages, client controller constructors, and server-module exports; it also verifies built-in weapon wield parts and attack/charge hitboxes resolve to BaseParts in the Studio weapon-model templates.
- `ParkourLifecycle.spec.lua`: verifies allowed traversal state transitions, hanging and mantle restoration, vault Jumping snapshot ownership after Jump release, and idempotent controller teardown.
- `ParkourMetrics.spec.lua`: verifies opt-in query counters, defensive snapshots, and reset behavior.

The suite currently defines **66 TestEZ cases** across these specs. This is a starting regression net, not exhaustive gameplay coverage; in particular, it does not simulate real parkour raycasts against the map, animation playback, or multiplayer combat timing.

The user confirmed **47 passed, 0 failed, 0 skipped** in Studio for the profiling revision. Four server combat lifecycle tests were then added; the initial 51-case run reported **50 passed, 1 failed, 0 skipped** because the character-replacement fixture marked its hit window already active and returned at the duplicate-start guard. The fixture and expectation were corrected, and the user subsequently confirmed **51 passed, 0 failed, 0 skipped**. Three weapon-attachment regression cases expanded the suite to 54, and the user confirmed **54 passed, 0 failed, 0 skipped** in Studio (the invalid-fixture warnings were expected). Two additional combat lifecycle specs brought the suite to 56, and the user confirmed **56 passed, 0 failed, 0 skipped** in Studio. Three client attack-callback ownership cases expanded the suite to 59, and the user confirmed **59 passed, 0 failed, 0 skipped** in Studio. Two inventory-contract cases and one built-in weapon-model runtime contract expanded it to 62, and the user confirmed **62 passed, 0 failed, 0 skipped** in Studio and reported that it works in game. Four input-reconciliation regression cases bring the suite to 66. The first Studio run reported **62 passed, 4 failed, 0 skipped**; all four errors had the same cause: the `MovementController.spec.lua` input test double did not initialize the `SourcesDown` state added by source-aware input tracking. The fixture was corrected to initialize and clear that state, and the user subsequently confirmed **66 passed, 0 failed, 0 skipped**. The user's ShiftTrace from the full overlapping-key reproduction showed one observed LeftShift begin, followed by an `InputEnded` identified as RightShift while `IsKeyDown()` and `GetKeysPressed()` still reported LeftShift down; no subsequent end event appeared. The PC adapter now handles this mismatch by releasing the sole tracked Shift source when an end arrives for the other Shift key, rather than letting the stale query preserve Sprint. Normal matched releases still reconcile from the pressed-key snapshot. Temporary traces remain enabled for event edges, periodic snapshots, and monitor stop reasons. The first 66-case suite passed after the MovementController fixture was corrected. A later 65-pass/1-fail run exposed an overlap-test fixture error: it pre-marked LeftShift held before calling the begin helper, suppressing the expected begin transition. The current test fixture removes that pre-mark and adds a regression matching the mismatched RightShift end / stale LeftShift snapshot. The current source and test patch await a fresh Studio rerun.

The user has confirmed the following physics-dependent parkour checks in Studio: death while hanging produced no errors; releasing Jump mid-vault allowed the vault to continue; focus loss/reacquisition worked; and resetting during mantle, vault, and top-hop produced no errors. The user later reported that the system functions as expected inside Studio; no outstanding Studio behavior failure is currently reported.

Follow-up Studio metrics confirmed the mantle bounds-filter reduction: mantle sampling fell from 210 to 126 columns and raycasts from 387–388 to 261–262; lower-ledge sampling remained at 84 columns with 176–177 raycasts. Later mantle timings were 0.77–0.81 ms, versus 0.90–0.93 ms in the first post-filter samples and 1.08–1.83 ms in the original baseline. These few timings are indicative only; query counts provide the clearer comparison. `ModelBoundsQueries=0` in the supplied Part-tagged mantle and lower-ledge samples, so the tested scene does not show repeated Model bounds work and does not currently justify bounds caching. The remaining guide-top and stacked-surface raycasts should be preserved unless targeted tests demonstrate that reducing them maintains stacked-ledge behavior.

The server combat hit path now checks current living-character identity and active-window expiry, with four isolated regression cases. Weapon attachment now reports missing templates and malformed bindings, guards Motor6D inputs, and has three focused specs. The 56-case suite, including attachment and combat cleanup coverage, passed in Studio. The user confirmed weapon swapping works and character death during a swing produces no errors. Client attack callbacks use an attack-generation identity guard to ignore stale marker and hitbox callbacks; three focused ownership specs were added, and the user confirmed the 59-case suite passed in Studio. The user reports that the system functions as expected inside Studio, with no outstanding Studio behavior failures. Inventory replication sends detached slot snapshots, and slot validation explicitly requires finite positive integers while retaining the current extensible no-cap contract; the user confirmed the 62-case suite passed and reported that the system works in game. Input actions now track their originating device family and individual physical control. A device-family change releases holds from the previous family, while keyboard/mouse transitions remain within the PC family; focus loss releases all active holds. Four focused reconciliation cases bring the suite to 66. The user confirmed the corrected fixture revision passed all 66 cases. The subsequent PC adapter patch uses one aggregate keyboard Sprint source and observed Shift event edges, with unmatched end identities consuming one outstanding tracked Shift press. It avoids `IsKeyDown()` because the supplied trace showed stale physical-state results for simultaneous modifiers. Focus loss and device changes reset tracked keys; the dual-Shift regression covers normal releases and mismatched end identities. Rerun the 66-case suite and live device checks after syncing this patch. The reported gameplay confirmation reflects the previously tested revision; the new input reconciliation changes still need Studio validation. Query profiling instructions are in the section above.

The behavior tests use isolated fixtures and avoid invoking live remotes or depending on map geometry. They are useful regression checks, but they do not replace Studio playtesting of real movement physics, parkour detection against authored map parts, animation asset availability, or multiplayer combat.
