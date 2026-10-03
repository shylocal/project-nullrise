# Architecture review

## Current shape

Nullrise uses explicit ModuleScript dependencies, domain controllers/services, Trove-owned lifecycles, shared weapon definitions, and a small shared remote protocol. That structure is appropriate for the current project; the main problem is responsibility concentration inside a few gameplay modules rather than the absence of a framework.

## Combat

`CombatService` is the security boundary. It owns player-scoped attack lifecycle, remote rate limits, combo sequencing, server timing, hit-window limits, and damage application. `CombatValidation` owns the spatial validation boundary.

`CombatController` is now an orchestration layer over `AttackInput`, `AttackLifecycle`, and `Hitbox`. The client does not advance the combo until the server acknowledges the requested attack, and hitmarker events are raised only from server-confirmed hits.

Weapon swaps reset combo sequence but preserve cooldown and remote-rate-limit state. Character removal clears all player-scoped state.

Remaining design debt: the shared weapon definitions still use 0.1-second cooldowns, which is a 10-attack-per-second authored cadence. That is a balance/configuration decision, not a validation hole; tune it deliberately before adding combat depth.

## Parkour

`ParkourController/init.lua` is the composition root, while queries, ledge traversal, vault traversal, state snapshots, and math live in separate modules. This is an improvement over a monolithic controller, but the extracted modules remain large and some functions are deeply nested.

The next decomposition should split geometry/classification from execution, not create more forwarding wrappers. In particular, `Queries` should return data, and traversal modules should consume that data without re-running detection.

Per-state parkour data is still stored as controller fields (`_vaultStart`, `_vaultElapsed`, `_mantleTarget`, `_topHopActive`, and related values). `State.lua` owns transition rules and Humanoid snapshots, but it does not yet own all execution-state data. A future refactor can move related fields into explicit Hang/Mantle/Vault/TopHop records.

## Input and UI

`InputController` is the device-normalization boundary. PC, touch, and gamepad adapters report logical actions plus source identity; UI selection no longer drives weapon restoration. The server's weapon event is the gameplay source of truth.

`AnimationController:Load` no longer blocks weapon state changes on `PreloadAsync`; asynchronous preload work is guarded by the owning animation trove.

## Inventory and weapon lifecycle

`InventoryService.Get` returns a detached snapshot, while mutation flows through validation methods. Inventory remotes are rate-limited.

`WeaponService` initializes player/character ownership independently of inventory signal ordering. Weapon templates are server-only in `ServerStorage.weapon_models`.

## Movement authority

Movement and parkour remain client-authoritative by design. This keeps the prototype responsive but means server combat range validation is not an anti-cheat guarantee against a client that can manipulate the server-observed character position. See `docs/THREAT_MODEL.md`.

## Build/runtime contract

`default.project.json` now declares the runtime containers for packages, UI templates, and server weapon models, and the server registers the required `Climbable` collision group at startup.

Those containers are still asset/package contracts rather than repository-complete source. The next step for a truly self-contained place is to vendor or otherwise source-control the approved package revisions and authored UI/weapon assets.

## Refactor rules

1. Extract a responsibility only when it owns distinct behavior or data.
2. Keep pure calculations free of Roblox service access.
3. Keep world queries separate from movement side effects.
4. Give each connection, task, instance, and temporary state one visible owner.
5. Add a regression test or explicit Studio scenario with each behavioral refactor.