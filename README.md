# project-nullrise

A Roblox game built with native Luau and Roblox primitives.

## Development model

- **Rojo** is the source-to-place sync/build tool.
- **Trove** owns disposable connections, instances, and controller/service lifetimes.
- **Signal** is used for in-process events.
- **Combat is server-authoritative.** Client reports are untrusted input to a server validation boundary.
- **Parkour/movement are client-authoritative prototype systems.** See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for the deliberate security boundary.
- **R6 is the supported character rig.** Set **Game Settings > Avatar > Avatar Type** to R6; this cannot be set from Rojo. The client warns and skips character setup on other rigs, and the server refuses to attach weapons to them, so they cannot attack.

## Layout

```
src/
├── client/
│   ├── controllers/
│   │   ├── AnimationController/   init, Movement, Weapon, Combat, TrackCache
│   │   ├── CharacterState/        init (leases, CanStart), Policy, HumanoidOverrides
│   │   ├── CombatController/      init, AttackInput, AttackLifecycle, Hitbox
│   │   ├── ParkourController/     init, State, InputLatch, ClimbableIndex, QueryContext,
│   │   │                          Queries, LedgeDetection, LedgeTraversal, Traversal,
│   │   │                          VaultTraversal, VaultMath, Metrics
│   │   ├── UIController/          init, Hitmarker, WeaponMenu, HitHighlight, DamageIndicator
│   │   ├── CharacterController.lua
│   │   ├── InputController.lua
│   │   ├── MovementController.lua
│   │   ├── PlayerController.lua
│   │   └── WeaponController.lua
│   ├── input/                     PC, Mobile, Gamepad
│   ├── session/                   CombatClient, LoadoutClient (the only remote listeners)
│   ├── UiContracts.lua            boot check of UI templates against the Catalog
│   └── init.client.lua            client composition root (Runtime)
├── server/
│   ├── AssetContracts.lua         boot check of weapon templates against the Catalog
│   ├── compose/                   Content, Core, Items, Combat (per-domain service composition)
│   ├── network/RemoteBudget.lua
│   ├── services/                  PlayerService, PlayerSession, Telemetry, PlayerDataService,
│   │                              InventoryService, WeaponService, WeaponAttachment,
│   │                              CombatService, CombatValidation, MoveKinds, DamageService,
│   │                              CombatFxService, PositionHistory, MovementValidation
│   ├── vendor/                    ProfileStore (server-only)
│   └── init.server.lua            server composition root (Runtime)
└── shared/
    ├── combat/                    CharacterQuery, RejectReason
    ├── config/                    validated, deep-frozen config tree + Envelope
    ├── data/Schema.lua            persisted profile shape, migrations, sanitising
    ├── input/Actions.lua
    ├── items/ItemCatalog.lua      every ownable item (a weapon item points at a Catalog weapon)
    ├── network/Protocol/          init, Combat, Inventory, Weapon, CombatFx
    ├── runtime/                   Runtime, Scheduler, Deps
    ├── utility/                   Vector, Freeze, Schema
    └── weapons/                   Catalog, Validator, Types, Loadouts, Fists, Katana,
                                   AnimationContracts, AnimationManifest
tests/
├── RunTests.lua
├── support/         (fakes: FakeClock, FakeRemote, FakeAnimationTrack, FakePlayers,
│                     FakeProfileStore, ServerHarness)
├── tools/           (Studio command-bar tools: BakeAnimationManifest)
└── specs/
```

Third-party packages come from Wally (Trove, and TestEZ for tests only; installed into the git-ignored `Packages/` and `DevPackages/`) or are vendored (`src/packages`: Signal, ShapecastHitbox; `src/server/vendor`: ProfileStore). Run `~/.rokit/bin/wally install` before `rojo serve` / `rojo build`. See [docs/VENDORED.md](docs/VENDORED.md).

## Runtime dependencies

Rojo now declares the expected containers so the place layout is visible in source:

- `ReplicatedStorage.packages`
- `ReplicatedStorage.ui`
- `ServerStorage.weapon_models`

Their required contents are documented in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md). The authored UI and weapon templates remain external assets; the source tree intentionally does not invent replacement art.

The server registers the `Climbable` collision group (`Config.World.CollisionGroups.Climbable`) during startup.

## Architecture

Both entry points compose their services with `shared/runtime/Runtime`: services are constructed in order, then started, and torn down in reverse. Constructor dependencies are passed as a `deps` table and checked with `Deps.check`. The server composes `Content` (the `AssetContracts` boot check of the weapon templates), then `Core` (Telemetry, PlayerService, RemoteBudget), `Items` (PlayerDataService, InventoryService, WeaponService) and `Combat` (PositionHistory, MovementValidation, DamageService, CombatFxService, CombatService). `PlayerService` drives registered components through the player lifecycle (session phase `Loading` -> `Ready` -> `Leaving`) and every per-player state lives on its `PlayerSession`. The client checks its UI templates with `UiContracts` before building anything. On the client, `CharacterController` builds the per-character controllers (CharacterState, WeaponController, AnimationController, MovementController, ParkourController, CombatController) and `CharacterState` arbitrates which actions may start (for example no attacks while hanging or vaulting). The design contract is [docs/REFACTOR_PLAN.md](docs/REFACTOR_PLAN.md).

## Combat rules

The server validates attack sequencing, attack rate, active hit windows, current character/weapon ownership, target Humanoids, mandatory hitpoint attachments, impact positions, facing, range, and line of sight before applying damage.

- **Data-driven moves.** Each weapon in `src/shared/weapons/*.lua` declares named `Moves` (Fists and Katana: `Light1`, `Light2`, `Heavy`), a `Combo` (`{ "Light1", "Light2" }`) and `Bindings.Primary = { Tap = "Combo", Hold = "Heavy" }`; `MoveDefaults` fills shared fields. A move's `Kind` is `Light` or `Charge`. The Catalog assigns each move an integer id (sorted by name), and every Combat payload carries a move id: the client sends `Attack(move_id)` for both tap and hold, and the server answers every accepted or rejected move with `AttackAccepted` / `AttackRejected`.
- **Per-move timing.** Every move defines `HitStartAt`, `HitWindow` and `MinDuration` (Charge moves also `Hold = { HoldTime, MaxHoldTime }`). An early `HitStart` is armed and opens the hit window at `HitStartAt`; hits after the window are rejected, and a new move before the previous one's `MinDuration` is rejected. A Charge move's hit window starts at its release, and the client releases it automatically at `MaxHoldTime`. `Cooldown` (client-side) must be at least `MinDuration`. Light attacks (the combo) repeat at most every 0.35s with Fists and every 0.6s with Katana (`Cooldown` = `MinDuration`); the Heavy repeats at most every 0.6s with either. Network jitter allowance, the client's pending-attack timeout, the per-move hit caps, lag compensation, damage and FX settings live in `src/shared/config/Combat.lua`.
- **Definitions are validated at load.** `Catalog` only serves the allowlisted weapons (Fists, Katana), collects every `Validator` error across all weapons and errors once on startup. `Catalog.DefaultId` (Fists) is the single source of the default weapon. When `AnimationManifest.lua` has been baked, `AnimationContracts` also checks move timing against the animations' markers.
- **Lag compensation.** `PositionHistory` records every live character's root and bounding box each Heartbeat. A hit that fails reach or body checks against the target's current position is retried against where the target was `ping + InterpolationDelay` ago (at most `MaxRewind`); such hits are counted as `Rewound`.
- **Damage and FX.** `DamageService` is the only place damage is dealt. Its policies (the `Invulnerable` attribute, spawn protection, team / friendly fire) can block a hit, and it tracks recent attackers. `HitConfirmed` (the hitmarker) is sent only when damage was actually applied. `CombatFxService` sends `CombatFx.Hit` over an unreliable remote to the victim and to players within `Fx.RelevanceRadius`; the client shows a brief highlight on the victim and, if the template exists, a damage flash for the victim.
- **Line of sight** is always checked from the attacker's root to the target's root (head to head as a fallback). Both characters, non-collidable parts and up to four bystander characters are ignored; anything else blocks the hit. The reported impact must be within `HitPositionTolerance` of the target's bounding box and of the weapon hitpoint.
- **Every well-formed Attack request that passes the remote budget gets exactly one reply**, `AttackAccepted` or `AttackRejected`. Malformed or budget-dropped requests get at most one `AttackRejected` per `RejectReplyInterval` (0.25s). The client also drops a pending attack after `PendingAttackTimeout`, and resets it on death and weapon swaps.
- **Every inbound remote action is budgeted** by `RemoteBudget` (per-action token buckets plus a global bucket per player, `Config.Network.RemoteBudget`), and every dropped request is counted in `Telemetry` with a `RejectReason`. In Studio, Telemetry prints one `[Telemetry] ...` summary line per flush (every 60s) when anything was counted.

Weapon changes reset combo sequencing but do **not** reset attack cooldown. Remote budget state lives for the whole session and is not reset by weapon changes or respawns. Player/character teardown clears all player-scoped combat state.

The client does not advance its combo until the server sends `AttackAccepted`, and the hitmarker only fires after `HitConfirmed`.

## Inventory

Items are defined in `src/shared/items/ItemCatalog.lua`; a weapon item points at a Catalog weapon, and the default weapon (Fists) is implicit and never an item. `InventoryService` holds up to `Config.Inventory.MaxSlots` (9) slots stored in the player's profile, each slot record being `{ Uid, ItemId, Data }`. A new profile is seeded once from `Catalog.Loadout("Starter")` (the Katana in slot 2). The server API is `Get`, `GetSelected`, `GetSelectedSlot`, `GetEquippedWeaponId`, `Grant`, `RemoveUid`, `SelectSlot` and `SelectUid`. Clients send `SelectSlot(n)` (`0` selects nothing; selecting the selected slot toggles back to nothing) or `SelectUid(uid)`. `Inventory.Changed` is sent as `(entries, selected_slot)`, where `entries` is a dense array of `{ Slot, Uid, ItemId }` sorted by slot and `selected_slot` is `0` when nothing is selected. The selection is not persisted. `WeaponService` caches each weapon model per character and coalesces rapid equip requests (`Inventory.EquipCoalesceWindow`). `LoadoutClient` is the only client listener for the Inventory and Weapon remotes; the UI and character controllers subscribe to its signals. PC hotkeys 1-9 select slots 1-9.

## Persistence

`PlayerDataService` (the first player component) loads each profile through ProfileStore v1.0.3 (vendored in `src/server/vendor`, Apache-2.0) with a session lock. The profile shape, its migration chain and load-time sanitising live in `src/shared/data/Schema.lua`. In Studio, `Config.Data.UseMockInStudio` (on by default) uses ProfileStore's mock store, so nothing is saved. On a live server a load failure kicks the player instead of playing on unsaved data, and another server taking the session lock kicks the player from this one; in Studio a load failure only warns and continues on an in-memory profile.

## Movement validation

Movement is client-authoritative. `MovementValidation` on the server only observes, logs and counts in Telemetry. Its limits are derived from the movement and parkour config by `src/shared/config/Envelope.lua`, so a tuning change moves them automatically: it judges total displacement over a sliding window of up to 1 second (at least 0.25 seconds of samples), with a downward-speed bound that grows with the height fallen. See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## Input

PC, touch, and gamepad adapters all feed `InputController`. Logical actions are de-duplicated by device family and physical source. Mobile includes the actions needed by parkour; gamepad has an explicit adapter.

## Tests

TestEZ specs live under `tests/specs` and are mapped into `TestService`, together with the TestEZ runner (a Wally dev dependency mapped from `DevPackages/`), so the test runner is not shipped to clients. The suite is intentionally run from Studio because several tests instantiate Roblox objects and the repository does not bundle Roblox Studio.

See [docs/TESTING.md](docs/TESTING.md) for setup and the current coverage boundary.

## Tooling

Aftman (`aftman.toml`, which Rokit also reads) pins Rojo, luau-lsp, selene and Wally. Wally (`wally.toml`, `wally.lock`) installs Trove and TestEZ into the git-ignored `Packages/` and `DevPackages/`; Rojo cannot build until it has run. There is no CI workflow (it was removed); run the checks, the build and the Studio test suite locally.

```sh
aftman install
~/.rokit/bin/wally install
sh scripts/analyze.sh          # luau-lsp (zero diagnostics) + selene (zero errors)
rojo build default.project.json -o build/project.rbxl
```

Run the live game with:

```sh
rojo serve
```

## Configuration

All tuning lives in the validated config tree `src/shared/config/` (`Movement`, `Parkour`, `Combat`, `Inventory`, `World`, `Network`, `Data`, `Telemetry`), required as `require(ReplicatedStorage.shared.config)`. It is validated at load with `shared/utility/Schema` (unknown keys are errors, every error is reported at once) and deep-frozen, so writing to it throws. Tag, collision-group, folder and attribute names live in `World.lua`. Avoid inline fallback defaults; configuration values have one source of truth.

Current vault values include a 13.5-stud maximum vault distance (`VaultMaxOverDistance`, the only vault distance cap), 2-stud landing gap, 12 studs/sec forward boost, 45% physical-exit progress, 8 studs/sec top-hop boost, and a 0.95 duration multiplier.

Movement speeds live in `src/shared/config/Movement.lua`. `MovementController` applies `WalkSpeed`/`SprintSpeed` to the Humanoid (it does not adopt the Humanoid's own WalkSpeed), and holding Sprint only sprints while `Humanoid.MoveDirection` is at least `SprintMinMoveMagnitude`, so standing still never sprints or vaults.

Use comments for invariants and constraints, not patch history or session notes.
