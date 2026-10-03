# Architecture review

## Current shape

Nullrise uses explicit ModuleScript dependencies, domain controllers/services, Trove-owned lifecycles, shared weapon definitions, and a small shared remote protocol. That structure is appropriate for the current project; the main problem is responsibility concentration inside a few gameplay modules rather than the absence of a framework.

## Combat

`CombatService` is the security boundary. It owns player-scoped attack lifecycle, remote rate limits, combo sequencing, server timing, hit-window limits, and damage application. `CombatValidation` owns the spatial validation boundary.

`CombatController` is now an orchestration layer over `AttackInput`, `AttackLifecycle`, and `Hitbox`. The client does not advance the combo until the server acknowledges the requested attack, and hitmarker events are raised only from server-confirmed hits.

Weapon swaps reset combo sequence but preserve cooldown and remote-rate-limit state. Character removal clears all player-scoped state.

Remaining design debt: the shared weapon definitions still use 0.1-second cooldowns, which is a 10-attack-per-second authored cadence. That is a balance/configuration decision, not a validation hole; tune it deliberately before adding combat depth.

## Parkour

`ParkourController/init.lua` is the composition root, while queries, ledge detection, ledge traversal, vault traversal, state snapshots, and math live in separate modules. `LedgeDetection` now owns tagged-guide broad-phase filtering, candidate sampling, surface classification/scoring, ground-mantle search, and destination-face probing; `LedgeTraversal` owns state transitions, rollback, positioning, and movement side effects. This keeps world-search logic out of the execution layer without adding controller forwarding shells.

The remaining decomposition work should be incremental and behavior-preserving. Queries return world data, detection/classification selects usable candidates, and traversal modules consume those results and own movement side effects. The controller no longer forwards most query/traversal methods.

Parkour execution data is owned by explicit `State` records for `Hanging`, `Mantling`, `Vaulting`, and `TopHop`. The controller retains only cross-state lifecycle concerns such as input guards, timing, and world references. State-specific update work now lives with the traversal module that owns it.

## Input and UI

`InputController` is the device-normalization boundary. PC, touch, and gamepad adapters report logical actions plus source identity; UI selection no longer drives weapon restoration. The server's weapon event is the gameplay source of truth.

`AnimationController:Load` no longer blocks weapon state changes on `PreloadAsync`; asynchronous preload work is guarded by the owning animation trove.

## Inventory and weapon lifecycle

`InventoryService.Get` returns a detached snapshot, while mutation flows through validation methods. Inventory remotes are rate-limited.

`WeaponService` initializes player/character ownership independently of inventory signal ordering. Weapon templates are server-only in `ServerStorage.weapon_models`.

## Movement authority

Movement and parkour remain client-authoritative by design. This keeps the prototype responsive. A server-side `MovementValidation` observer now records extreme replicated displacement/velocity anomalies without correcting or rejecting movement. It provides observability while preserving the client-owned traversal model; see `docs/THREAT_MODEL.md` for the measured envelope and multiplayer validation scenarios.

This remains a prototype boundary rather than server-authoritative movement, so combat range checks still depend on the server-observed character position.

## Build/runtime contract

`default.project.json` now declares the runtime containers for packages, UI templates, and server weapon models, and the server registers the required `Climbable` collision group at startup.

Those containers are still asset/package contracts rather than repository-complete source. The next step for a truly self-contained place is to vendor or otherwise source-control the approved package revisions and authored UI/weapon assets.

## Refactor rules

1. Extract a responsibility only when it owns distinct behavior or data.
2. Keep pure calculations free of Roblox service access.
3. Keep world queries separate from movement side effects.
4. Give each connection, task, instance, and temporary state one visible owner.
5. Add a regression test or explicit Studio scenario with each behavioral refactor.