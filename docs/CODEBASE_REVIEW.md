# Codebase Review and Refactor Plan

Reviewed repository structure and representative client controllers, parkour, combat, inventory, weapon, and player-session code on 2026-09-30. Static review only; Roblox Studio execution, Luau analysis, and multiplayer playtesting were not available.

## Executive assessment

The project has a sensible foundation: native Luau, explicit dependencies, focused service/controller ownership, Trove cleanup, and server-side combat validation. The main risk is not a need for a framework. Several modules are orchestration hubs, state ownership is spread across booleans and saved-property fields, and lifecycle/input assumptions are implicit. A large rewrite in one pass would increase regression risk. Refactor in small, behavior-preserving slices with tests and reviewable commits.

## Refactor progress (2026-09-30)

Since the initial static review, the following behavior-preserving module boundaries have been introduced:

- Parkour spatial operations: `ParkourController/Queries.lua` owns raycast/overlap helpers and surface detection.
- Parkour movement domains: `Traversal.lua` owns lateral hang traversal and pose snapshots; `LedgeTraversal.lua` owns ledge selection, transfers, and mantle searches; `VaultTraversal.lua` owns vault/top-hop setup and completion.
- Parkour support: `ClimbableQuery.lua` owns tagged-guide discovery; `VaultMath.lua` owns pure vault easing/trajectory math; `Config.lua` remains the tuning source.
- Combat input: `CombatController/AttackInput.lua` owns primary press buffering and charge intent.
- Combat execution: `CombatController/AttackLifecycle.lua` owns attack setup, animation-marker wiring, hitbox lifecycle, sprint policy, and lifecycle cleanup. `CombatController/init.lua` remains the composition/orchestration layer, with the finish callback and public Attack/Charge/Reset interface.

The main ParkourController module is now 466 lines (from roughly 2,200 before decomposition); CombatController/init.lua is 203 lines (from 456 before decomposition). The remaining PlayerController, CharacterController, MovementController, UIController, and AnimationController already have narrow orchestration or domain roles, so they were not split merely to reduce line count.

Static consistency checks confirmed the extracted module references and controller-method calls. The user has since confirmed the recent parkour grab/traversal and vault behavior in Roblox Studio. The source review itself did not run Luau analysis or automated gameplay tests.

## TestEZ setup (2026-09-30)

A starter TestEZ suite is now present. The Rojo project maps the root `tests/` directory into Roblox `TestService`; the manual runner is guarded to Studio and does not execute automatically. Initial specs cover the shared Vector helper and weapon catalog. The runner expects TestEZ at `ReplicatedStorage.packages.TestEZ`, following the project's Roblox-managed package convention; installation and usage instructions are in `docs/TESTING.md`.

The test harness and specs are committed, but TestEZ installation and execution in Studio remain to be completed by the developer. No test pass is claimed by this source-only setup.

## Findings

### P0 — Lifecycle and state restoration
- Parkour traversal modes modify Humanoid state, movement locks, and root motion. Cleanup is distributed across release, vault completion, mantle completion, and Destroy; new exit paths can omit restoration.
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
- WeaponService attachment silently returns when an asset or attachment is missing. Add diagnostics or explicit failure results so content errors are visible.
- CombatController schedules delayed work and waits for animation completion. Identity checks protect some callbacks; test stale callbacks during teardown, weapon swaps, and death.
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
- ParkourController/State.lua: transitions and Humanoid snapshot/restore; no raycasts.
- ParkourController/Queries.lua: raycast/overlap setup and spatial queries.
- ParkourController/Detection.lua: data-oriented classification over query results.
- ParkourController/Traversal.lua: hang, mantle, vault, and hop execution.
- Keep ParkourController/init.lua as a composition root for dependencies, input/heartbeat connections, delegation, and teardown.

Avoid a generic Common/Utils dumping ground. Shared utilities should be pure, domain-named, and genuinely reused.

## Refactor sequence

1. Safety baseline: test death and Destroy in every parkour state, focus loss while Jump is held, overlapping hop requests, weapon swap during attack, and player removal during combat.
2. Parkour lifecycle: one transition path, one Humanoid snapshot, idempotent cleanup, explicit enter/exit behavior, and one owner per movement lock.
3. Parkour performance: maintain tagged guides through CollectionService signals, spatially filter candidates, cache model bounds with invalidation, cache ancestry, and avoid unnecessary corner fans. Measure raycast counts.
4. Parkour decomposition: extract query, detection/classification, landing search, and execution in that order. Keep detection/classification data-only and unit-testable.
5. Input reconciliation: clear/reconcile held actions on focus loss and device changes, emitting matching end transitions.
6. Combat lifecycle: explicit attack/charge phases, centralized cleanup, and stale callback guards using character/weapon/attack identity.
7. Inventory/weapon contracts: bound slot indices, copy replication payloads, report attachment/equip failures, and validate catalog data.
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

This is a source-inspection review, not a complete execution audit. Additional animation, UI, input-adapter, player-service, attachment, validation, and weapon-definition modules need focused follow-up review. No runtime correctness or performance improvement is claimed until tested in Studio and measured.