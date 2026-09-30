# Codebase Review and Refactor Plan

Reviewed repository structure and representative client controllers, parkour, combat, inventory, weapon, and player-session code on 2026-09-30. Static review only; Roblox Studio execution, Luau analysis, and multiplayer playtesting were not available.

## Executive assessment

The project has a sensible foundation: native Luau, explicit dependencies, focused service/controller ownership, Trove cleanup, and server-side combat validation. The main risk is not a need for a framework. Several modules are orchestration hubs, state ownership is spread across booleans and saved-property fields, and lifecycle/input assumptions are implicit. A large rewrite in one pass would increase regression risk. Refactor in small, behavior-preserving slices with tests and reviewable commits.

## Refactor progress (2026-09-30)

Since the initial static review, the following behavior-preserving module boundaries have been introduced:

- Parkour spatial operations: `ParkourController/Queries.lua` owns raycast/overlap helpers and surface detection.
- Parkour movement domains: `Traversal.lua` owns lateral hang traversal and pose snapshots; `LedgeTraversal.lua` owns ledge selection, transfers, and mantle searches; `VaultTraversal.lua` owns vault/top-hop setup and completion.
- Parkour support: `ClimbableQuery.lua` owns tagged-guide discovery; `VaultMath.lua` owns pure vault easing/trajectory math; `Config.lua` remains the tuning source.
- Parkour lifecycle ownership: `ParkourController/State.lua` owns allowed traversal transitions and keyed Humanoid snapshots/restoration. The controller, ledge traversal, and vault traversal delegate state changes and temporary Humanoid-property ownership to it; traversal geometry and movement remain in their existing modules. Jump release during a scripted vault retains the saved Jumping setting until vault cleanup. `Destroy()` is idempotent and the heartbeat step exits after destruction. The user confirmed the 47-case TestEZ revision passed in Studio.
- Parkour query profiling and first measured optimization: `Metrics.lua` provides opt-in per-search counters for raycasts, overlap queries, tagged-guide enumeration, bounds classification, sampled columns, guide-top rays, `Model:GetBoundingBox()` calls (`ModelBoundsQueries`), and elapsed search time. It is enabled only by setting the local character's `ParkourQueryMetrics` attribute to true; it resets and reports per mantle/lower-ledge search. `ParkourMetrics.spec.lua` covers opt-in collection, snapshots, reset, and the bounds-query counter. The user confirmed the current 47-case TestEZ suite passed in Studio (`47 passed, 0 failed, 0 skipped`). The original Studio baseline sampled 210 mantle columns with 387–388 raycasts; after applying the existing conservative bounds check before upper-mantle sampling, repeated Studio output showed 126 columns and 261–262 raycasts (40% fewer columns and about 32.5% fewer raycasts). Lower-ledge remained at 84 columns and 176–177 raycasts. Later mantle samples were 0.77–0.81 ms, compared with 0.90–0.93 ms in the first post-filter samples and 1.08–1.83 ms in the original baseline; this small sample is indicative, not a stable benchmark. `ModelBoundsQueries=0` in both mantle and lower-ledge samples, so there is no evidence from this tested layout to justify bounds caching; it may simply be exercising tagged BasePart guides rather than Models. No further query optimization has been applied. Remaining guide-top and stacked-surface rays preserve the multi-surface ledge search and should not be reduced without targeted behavior tests.
- Combat input: `CombatController/AttackInput.lua` owns primary press buffering and charge intent.
- Combat execution: `CombatController/AttackLifecycle.lua` owns attack setup, animation-marker wiring, hitbox lifecycle, sprint policy, and lifecycle cleanup. `CombatController/init.lua` remains the composition/orchestration layer, with the finish callback and public Attack/Charge/Reset interface.
- Server combat lifecycle hardening: `CombatService` checks that an active attack still belongs to the player's current, living character at hit activation and hit application, and clears active state after expiry instead of depending only on the delayed cleanup callback. `CombatService.spec.lua` adds four isolated tests for death, character replacement, expired windows, and valid hit activation. The initial Studio run reported 50 passed and one failed because the replacement fixture marked the hit window active, triggering the duplicate-start guard before the stale-character check. The fixture and expectation were corrected, and the user confirmed the 51-case rerun passed. The follow-on weapon-attachment slice adds malformed-binding guards, diagnostic warnings, and three isolated regression cases; the user confirmed the 54-case Studio suite passed (`54 passed, 0 failed, 0 skipped`; attachment-fixture warnings were expected). Two more combat lifecycle tests cover weapon-change reset and player removal, and the user confirmed the 56-case suite passed (`56 passed, 0 failed, 0 skipped`). The user also confirmed weapon swapping works and character death during a swing produces no errors. A subsequent client callback-ownership slice adds attack-generation guards and three tests; the 59-case suite is pending.

The main ParkourController module is now 466 lines (from roughly 2,200 before decomposition); CombatController/init.lua is 203 lines (from 456 before decomposition). The remaining PlayerController, CharacterController, MovementController, UIController, and AnimationController already have narrow orchestration or domain roles, so they were not split merely to reduce line count.

Static consistency checks confirmed the extracted module references and controller-method calls. The user has since confirmed the recent parkour grab/traversal and vault behavior in Roblox Studio. The source review itself did not run Luau analysis or automated gameplay tests.

## TestEZ setup (2026-09-30)

An expanded TestEZ suite is now present. The Rojo project maps the contents of `tests/` directly into Roblox `TestService`; the manual runner is Studio-guarded and does not execute automatically. The 59 cases cover pure parkour math and tuning invariants, parkour lifecycle cleanup/state transitions with isolated controller fixtures, opt-in query metrics, input-state transitions, movement/sprint behavior with an isolated Humanoid fixture, weapon catalog/definition shape, weapon attachment preparation and malformed-binding handling, shared protocol identifiers, malformed combat payload rejection, inventory slot validation, server combat lifecycle guards including weapon-change reset and player removal, client attack-callback generation ownership, and client/server module/runtime contracts. The runner expects TestEZ at `ReplicatedStorage.packages.TestEZ`, following the project's Roblox-managed package convention; installation and usage instructions are in `docs/TESTING.md`.

The user confirmed 47 TestEZ cases passed in Studio before the four server-combat specs were added. The initial 51-case run reported 50 passed and one failed in the character-replacement test because its fixture marked the hit window already active, causing the duplicate-start guard to return before exercising the stale-character check. The fixture was corrected to represent a pending hit activation, and the user confirmed the corrected 51-case suite passed. Three weapon-attachment specs brought the suite to 54, and the user confirmed `54 passed, 0 failed, 0 skipped` in Studio; the expected warnings came from invalid attachment fixtures. Two more combat lifecycle specs brought the suite to 56, and the user confirmed that run passed (`56 passed, 0 failed, 0 skipped`). The user also confirmed weapon swapping works and character death during a swing produces no errors. Three client attack-callback ownership specs now bring the current suite to 59, which still needs a Studio run. The user has confirmed parkour checks: death while hanging produced no errors, releasing Jump mid-vault continued the vault, focus loss/reacquisition worked, and resetting during mantle, vault, and top-hop produced no errors. Recovery of movement, jumping, and sprint after each reset should still be explicitly observed. Follow-up metrics confirm the mantle query reduction and `ModelBoundsQueries=0` in the sampled Part-tagged scene; Model-bounds caching remains deferred.

## Findings

### P0 — Lifecycle and state restoration
- Parkour traversal modifies Humanoid state, movement locks, and root motion. Allowed transitions and keyed Humanoid snapshots are centralized in `ParkourController/State.lua`; vault, mantle, and hang owners delegate temporary property restoration to it. Traversal-specific animation/trajectory fields remain owned by the execution modules. The user reports no errors when dying while hanging or resetting during mantle, vault, and top-hop; releasing Jump mid-vault continues safely, and focus loss/reacquisition works. Explicitly confirm movement, jumping, and sprint restoration on the replacement character after each reset.
- Parkour stores related snapshots in separate fields for hang, mantle, and vault. This obscures ownership and restoration order.
- InputController now releases held actions on window focus loss. Device-change reconciliation and lifecycle behavior still merit focused verification.
- CharacterController attaches its Trove to the character and exposes Destroy. Idempotence exists, but dependent-controller teardown ordering should be tested.

### P1 — Excessive responsibility and complexity
- ParkourController/init.lua is approximately 81 KB and combines input orchestration, query setup, climbable discovery, geometry, traversal selection/execution, Humanoid mutation, and cleanup. It is the clearest refactor target.
- CombatController combines input buffering, attack/charge state, animation markers, remotes, hitbox lifecycle, cooldowns, and movement locks. Separate its state machine from animation, hitbox, and network adapters.
- CombatService combines remote throttling, player lifecycle, attack state, timing validation, and damage application. Keep validation authoritative while reducing coupling where useful.
- InventoryService combines inventory mutation, selection, replication, and starter-slot policy. These may separate as rules expand.

### P1 — Correctness and security risks to verify
- Inventory SetSlot and SelectSlot validate positive integer slots but do not impose an upper bound. This is a design decision to resolve if the game uses a fixed hotbar; otherwise sparse/unbounded slots may be intentional.
- Inventory replication sends the live Slots table. Remote serialization copies values, but explicit payload copying clarifies ownership and avoids future mutation coupling.
- `WeaponAttachment` now warns for invalid templates and malformed wield bindings, validates names and `BasePart` types before creating `Motor6D`s, and skips only the invalid binding so valid entries can still attach. `WeaponService` now warns when an equipped model template is missing. The three new attachment specs cover successful preparation/binding/tagging, invalid-model cleanup, and malformed entries; actual authored weapon-to-rig bindings still need Studio validation.
- CombatController schedules delayed work and waits for animation completion. The server independently validates current living-character identity and attack expiry on hit activation/application. The user confirmed weapon swapping works and character death during a swing produces no errors; isolated server tests also cover weapon-change reset and player removal. Client attack callbacks now capture the active Trove and a monotonically advancing attack-generation ID; stale marker and hitbox callbacks are ignored, and the delayed cooldown callback is invalidated by reset or a newer attack while remaining valid after the animation ends. Three tests cover current versus replaced/stale lifecycle ownership; the expanded 59-case suite needs a Studio rerun. Actual character teardown, replacement-character damage rejection, and callback timing still merit focused playtesting.
- Server combat validation is a sound boundary. Continue treating client-reported targets, segments, and positions as untrusted.

### P2 — Readability and maintainability
- Some modules use verbose callback wrappers and repeated guard/cleanup patterns. Prefer short local functions and consistent formatting, not abstraction for its own sake.
- Defaults are split between config and inline fallbacks. Define defaults once and validate config at startup.
- Comments should explain invariants and constraints, not narrate previous bugs or history.
- Use names that express state and units; avoid fields shared across unrelated state machines.

## Proposed structure

Keep the existing controller/service architecture and add focused modules only when they remove real responsibility:
- shared/utility/Vector.lua: pure vector helpers such as safeUnit; no service access.
- shared/utility/Validation.lua: finite-number and bounded-integer predicates only if multiple domains need them.
- `ParkourController/State.lua`: allowed traversal transitions and keyed Humanoid snapshot/restore; no raycasts or movement execution.
- ParkourController/Queries.lua: raycast/overlap setup and spatial queries.
- ParkourController/Detection.lua: data-oriented classification over query results.
- ParkourController/Traversal.lua: hang, mantle, vault, and hop execution.
- Keep ParkourController/init.lua as a composition root for dependencies, input/heartbeat connections, delegation, and teardown.

Avoid a generic Common/Utils dumping ground. Shared utilities should be pure, domain-named, and genuinely reused.

## Refactor sequence

1. Safety baseline: test death and Destroy in every parkour state, focus loss while Jump is held, overlapping hop requests, weapon swap during attack, and player removal during combat.
2. Parkour lifecycle: allowed transitions and Humanoid snapshots/restoration live in `ParkourController/State.lua`, with five isolated regression cases. The user confirmed death while hanging, mid-vault Jump release, and focus-loss behavior in Studio. Continue with reset during mantle and vault/top-hop, plus explicit checks that the replacement character can move, jump, and sprint.
3. Parkour performance: profiling identified two out-of-bounds guides still being sampled during mantle search. Applying the existing conservative guide-bounds filter reduced the user's measured mantle workload from 210 to 126 columns and 387–388 to 261–262 raycasts; lower-ledge counts remained effectively unchanged, and the user confirmed the current 47-case TestEZ suite. The subsequent `ModelBoundsQueries=0` measurements do not justify a bounds cache in the tested layout, so defer that optimization unless a Model-heavy scenario shows meaningful repeated calls. Preserve the multi-surface guide-top/stack raycasts unless focused behavior tests establish that a reduction is safe.
4. Parkour decomposition: extract query, detection/classification, landing search, and execution in that order. Keep detection/classification data-only and unit-testable.
5. Input reconciliation: clear/reconcile held actions on focus loss and device changes, emitting matching end transitions.
6. Combat lifecycle: the server now rejects hits from dead/replaced characters and expired active windows, backed by four isolated `CombatService` tests. Weapon-change reset and player-removal cleanup have isolated regression tests, and the user confirmed the 56-case suite passed. Attack-generation guards and three callback-ownership specs have since been added; rerun the 59-case suite, then cover actual character teardown, replacement-character damage rejection, and animation-marker races in Studio before changing combat architecture further.
7. Inventory/weapon contracts: bound slot indices, copy replication payloads, finish attachment/equip failure handling where needed, and validate catalog data. Attachment diagnostics and focused specs are now in place.
8. Consistency: centralize genuinely shared pure helpers, validate config, improve comments/formatting, and add CI after confirming the toolchain.

## Working rules for simple, readable code

- One module, one reason to change.
- Prefer straight-line code and early returns over deep nesting.
- Prefer explicit states and transition functions over flag combinations.
- Separate pure calculations from world queries and side effects.
- Give every connection, task, instance, and lock one visible cleanup owner.
- Do not abstract solely to reduce line count.
- Each refactor commit should preserve behavior and include a test or manual verification checklist.

## Limitations

This is a source-inspection review, not a complete execution audit. Additional animation, UI, input-adapter, player-service, attachment, validation, and weapon-definition modules need focused follow-up review. No runtime correctness or performance improvement is claimed until tested in Studio and measured. The user has confirmed the 51-case and 54-case suites passed in Studio, followed by the 56-case suite (`56 passed, 0 failed, 0 skipped`). They also confirmed weapon swapping works and character death during a swing produces no errors. Three client attack-callback ownership tests bring the current suite to 59; this latest run is pending.