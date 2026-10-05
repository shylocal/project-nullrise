# Architecture review

This review assessed the pre-refactor architecture. **Every item is now done.** Each entry says where; [ARCHITECTURE.md](ARCHITECTURE.md) describes the result, and the "§14.N" numbers refer to its list of intentional behaviour changes.

## Current shape: **Done**

The game keeps explicit ModuleScript dependencies rather than a framework. On top of them sit:

- one `Runtime` per scope (server, client, character), with ordered construction and Start and reverse teardown;
- constructor `deps` tables checked by `Deps.check`;
- `PlayerService` components, with per-player state stored on the `PlayerSession`.

Responsibility concentration was addressed by splitting combat, parkour, persistence and transport into focused modules.
Where: ARCHITECTURE.md §1–§4.

## Combat: **Done**

- `CombatService` remains the security boundary: per-player move lifecycle, combo sequencing, server timing and the hit buffer.
- Transport limits moved to `RemoteBudget`.
- Damage moved to `DamageService` (the only `TakeDamage` caller, with policies).
- FX moved to `CombatFxService`.
- Spatial validation stays in `CombatValidation`, now lag-compensated through `PositionHistory`.
- The client `CombatController` orchestrates `AttackInput`, `AttackLifecycle` and `Hitbox`. It advances the combo only on `AttackAccepted`, and the hitmarker fires only on `HitConfirmed`.

Weapon swaps reset the combo but keep the cooldown and budget. Character removal clears player-scoped state.

The 0.1s cooldowns were replaced by a server-enforced `MinDuration` per move, with the client `Cooldown` validated to be no shorter. The current values are: Fists lights 0.35s, Katana lights 0.6s (user decision, §14.22) and Heavies 0.6s. `AnimationContracts` checks them against the animations once the manifest is baked.
Where: ARCHITECTURE.md §5, §6; `src/shared/weapons/{Fists,Katana}.lua`; `WeaponGolden.spec`.

## Parkour: **Done**

`ParkourController/init.lua` composes the queries, detection, traversal, vault and math modules. Its state is a typed machine (`State.lua`) whose data exists only inside its state, and transitions are checked against a table.

Several things now go through shared owners:

- **Leases:** `CharacterState` arbitrates which actions may start.
- **Humanoid properties:** layered through `HumanoidOverrides` stacks, which restore base values.
- **Input latches:** `InputLatch`.
- **Climbable lookups:** a spatial-hash `ClimbableIndex`. It survives respawns and re-measures moved guides (§14.15).
- **Workspace queries:** go through `QueryContext`, with per-frame ray metrics.

Where: ARCHITECTURE.md §7.

## Input and UI: **Done**

`InputController` is the device-normalisation boundary. The UI is session-scoped: `UIController` modules subscribe to the session clients (`CombatClient`, `LoadoutClient`), which are the only remote listeners. The modules survive respawn, and each template is optional.

Animation loading no longer blocks on `PreloadAsync`: `TrackCache.preload` preloads every Catalog animation once in the background at boot. Tracks are cached per Animator and role.
Where: `src/client/init.client.lua`, `src/client/session/`, `AnimationController/TrackCache.lua`; ARCHITECTURE.md §3.3.

## Inventory and weapon lifecycle: **Done**

`InventoryService` stores slots in the persisted profile (`{ Uid, ItemId, Data }` records, ProfileStore with a session lock). `Inventory.Changed` sends a dense `{ Slot, Uid, ItemId }` array plus the selected slot (`0` = none). Clients select by `SelectSlot` or `SelectUid`. `LoadoutClient`, not `PlayerController`, is the single client listener.

`WeaponService` is a component that does not depend on inventory signal order. It caches models per character, coalesces rapid equips, and attaches only to R6. Templates are server-only, in `ServerStorage.weapon_models`.
Where: ARCHITECTURE.md §8.

## Movement authority: **Done (by design)**

Movement and parkour stay client-authoritative. `MovementValidation` observes the replicated position through `PositionHistory`, with limits derived from config by `Envelope`, and counts anomalies in Telemetry without correcting them.
Where: [THREAT_MODEL.md](THREAT_MODEL.md).

## Build/runtime contract: **Done**

`default.project.json` declares the package, UI, weapon-model and remote containers, and the server registers the `Climbable` collision group at startup. Trove and TestEZ come from Wally (`wally.toml`, `wally.lock`). Signal, ShapecastHitbox and ProfileStore are vendored with provenance in [VENDORED.md](VENDORED.md). Authored UI and weapon assets stay in Studio by design and are verified at boot by `UiContracts` and `AssetContracts`.
Where: [DEPENDENCIES.md](DEPENDENCIES.md).

## Refactor rules

These still apply to future work:

1. Extract a responsibility only when it owns distinct behaviour or data.
2. Keep pure calculations free of Roblox service access.
3. Keep world queries separate from movement side effects.
4. Give each connection, task, instance, and temporary state one visible owner.
5. Add a regression test or explicit Studio scenario with each behavioural refactor.
