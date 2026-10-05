# Architecture

This document describes how project-nullrise is built today. It replaces the refactor design contract (`docs/REFACTOR_PLAN.md`), which is summarised in [History](#history) at the end. When this document and the code disagree, the code wins; fix the document.

Related documents: [DEPENDENCIES.md](DEPENDENCIES.md) (place contents the code expects), [THREAT_MODEL.md](THREAT_MODEL.md) (trust boundary), [TESTING.md](TESTING.md) (specs and smoke tests), [VENDORED.md](VENDORED.md) (third-party code).

## 1. Principles

- **Composition, not a framework.** Explicit `require`s, constructor `deps` tables checked with `shared/runtime/Deps.check`, and an ordered `Runtime` per scope (server, client, character).
- **Server-authoritative combat and items; client-authoritative movement.** The server validates every combat and inventory request and owns damage and persistence. Movement and parkour run on the client; the server only observes them (`MovementValidation`).
- **One validated config tree.** `src/shared/config` is checked with `shared/utility/Schema` at load (unknown keys are errors, every error is reported at once) and deep-frozen. There are no `x or default` fallbacks.
- **Data-driven content.** Weapons, moves, items and loadouts are plain tables validated when the Catalog loads. Studio-authored assets are checked against the Catalog at boot.
- **Every resource has one owner.** Trove (Wally `sleitnick/trove@1.8.0`) for cleanup, `packages.Signal` for in-process events, `PlayerSession` for per-player server state.
- **`--!strict` everywhere** under `src/**` and `tests/**`, except vendored code (`src/packages/**`, `src/server/vendor/**`).
- **House style:** tabs; `snake_case` locals and module-private functions; `PascalCase` public methods, fields, module tables and signals; comments describe invariants, not history.

## 2. Module map

Rojo (`default.project.json`) maps `src/shared` to `ReplicatedStorage.shared`, `src/server` to `ServerScriptService.server`, `src/client` to `StarterPlayer.StarterPlayerScripts.client` and `tests` to `TestService`. `ReplicatedStorage.packages` holds `Trove` and `_Index` (from `Packages/`), plus `Signal` and `ShapecastHitbox` (from `src/packages`). `TestService.TestEZ` comes from `DevPackages/`. The place also declares the empty folders `ReplicatedStorage.ui` and `ServerStorage.weapon_models`, and the `ReplicatedStorage.remotes` folder (`Sandboxed = true`).

### Shared (`src/shared`)

| Module | Role |
| --- | --- |
| `config/` (`init`, `Movement`, `Parkour`, `Combat`, `Inventory`, `World`, `Network`, `Data`, `Telemetry`) | The validated, deep-frozen config tree: `require(ReplicatedStorage.shared.config)`. `Config.validate(sections)` is the pure checker that specs use. |
| `config/Envelope.lua` | Pure. Derives the movement observer's limits from the Movement and Parkour config (`Envelope.compute`, `Envelope.sources`). |
| `runtime/Runtime.lua` | Ordered construction, then `Start`, then reverse teardown (§3). |
| `runtime/Scheduler.lua` | `{ clock, after }` closures. `Scheduler.real()` uses `os.clock` / `task.delay`; specs use `FakeClock`. |
| `runtime/Deps.lua` | `Deps.check(deps, owner, required)`. Every constructor dependency is required. |
| `combat/CharacterQuery.lua` | `resolve`, `is_alive` and `resolve_alive`: the character Model and Humanoid for any part, including parts of a nested weapon Model. Used by the client hitbox, server validation, line of sight and damage. |
| `combat/RejectReason.lua` | Frozen enum of reason codes for dropped or rejected requests (also the Telemetry keys). |
| `weapons/` | `Catalog`, `Validator`, `Types`, `Loadouts`, `Fists`, `Katana`, `AnimationContracts`, `AnimationManifest` (§6.1, §9). |
| `items/ItemCatalog.lua` | Ownable items. Each weapon item points at a Catalog weapon; the default weapon (Fists) is never an item. |
| `data/Schema.lua` | The persisted profile: shape, template, migrations, validation and sanitising (§8). |
| `network/Protocol/` | Action-name tables, one per remote: `Combat`, `Inventory`, `Weapon`, `CombatFx`. |
| `input/Actions.lua` | Logical action names, with `Slot1`..`Slot9` generated from `Config.Inventory.MaxSlots`. |
| `utility/` | `Vector`, `Freeze` (`deep`, `clone_deep`) and `Schema` (declarative checks). |

### Server (`src/server`)

| Module | Role |
| --- | --- |
| `init.server.lua` | Registers the `Climbable` collision group, builds the `ServerEnv`, composes `Content`, `Core`, `Items` and `Combat` into one Runtime, and starts it. |
| `compose/Content.lua` | `AssetContracts` boot check (§9.1). |
| `compose/Core.lua` | `Telemetry`, `PlayerService`, `RemoteBudget`. Defines `ServerEnv`. |
| `compose/Items.lua` | `PlayerDataService` (with the ProfileStore store), `InventoryService`, `WeaponService`, `WeaponInbound`. |
| `compose/Combat.lua` | `PositionHistory`, `MovementValidation`, `DamageService`, `CombatFxService`, `CombatFxInbound`, `CombatService`. |
| `compose/Remotes.lua` | Typed remote lookups. A missing or mistyped remote is an error raised inside the factory that needs it. |
| `AssetContracts.lua` | Verifies `ServerStorage.weapon_models` against the Catalog. |
| `network/RemoteBudget.lua` | Per-player token buckets (§5.3). |
| `network/InboundSink.lua` | Drains client events fired at server-to-client remotes (§5.3). |
| `services/PlayerService.lua`, `PlayerSession.lua` | Player lifecycle and per-player state (§4). |
| `services/Telemetry.lua` | Decaying per-player suspicion, reason counters, AnalyticsService flushes. |
| `services/PlayerDataService.lua` | ProfileStore sessions (§8). |
| `services/InventoryService.lua` | Slots stored in the profile; selection (§8). |
| `services/WeaponService.lua`, `WeaponAttachment.lua` | The equipped weapon, model caching, equip coalescing and welding to the R6 rig. |
| `services/CombatService.lua`, `MoveKinds.lua`, `CombatValidation.lua` | Combat requests, move timing and hit validation (§6). |
| `services/PositionHistory.lua` | Ring buffer of character root and bounding-box samples (lag compensation; source for the movement observer). |
| `services/DamageService.lua` | The only place damage is dealt (§6.6). |
| `services/CombatFxService.lua` | Relevance-filtered hit FX over an unreliable remote. |
| `services/MovementValidation.lua` | Observe-only movement anomaly detection ([THREAT_MODEL.md](THREAT_MODEL.md)). |
| `vendor/ProfileStore.lua` | Vendored ProfileStore v1.0.3 (Apache-2.0). Server-only. |

### Client (`src/client`)

| Module | Role |
| --- | --- |
| `init.client.lua` | Client composition root (§3.2). |
| `UiContracts.lua` | Boot check of the UI templates against the Catalog. |
| `ClientTrove.lua` | Typed, non-generic front for Trove 1.8. Every client module requires this instead of `packages.Trove`. |
| `session/CombatClient.lua` | The only listener on `Combat` and `CombatFx`. Validates payloads and re-emits them as signals. |
| `session/LoadoutClient.lua` | The only listener on `Inventory` and `Weapon`. Holds `EquippedId`, `Entries` and `SelectedSlot`. |
| `input/` (`PC`, `Mobile`, `Gamepad`) | Device adapters that feed `InputController`. |
| `controllers/InputController.lua` | Normalises devices into logical actions, de-duplicated by device family and physical source. On focus loss it releases everything and calls each adapter's optional `ReleaseAll`. |
| `controllers/PlayerController.lua` | Waits for each character in Workspace, builds a `CharacterController` for it, and maps slot hotkeys to `LoadoutClient:SelectSlot`. |
| `controllers/CharacterController.lua` | Per-character Runtime (§3.3). Rejects non-R6 rigs. |
| `controllers/CharacterState/` | Lease arbiter, `Policy`, `HumanoidOverrides` (§7.2). |
| `controllers/WeaponController.lua` | The equipped definition and cached wield lookups for the local character. |
| `controllers/AnimationController/` | `TrackCache`, and the `Movement`, `Weapon` and `Combat` layers. |
| `controllers/MovementController.lua` | The only writer of `Humanoid.WalkSpeed` (walk and sprint). |
| `controllers/ParkourController/` | Hang, traverse, corners, mantle, lower-ledge, vault and top-hop (§7). |
| `controllers/CombatController/` | `AttackInput` (tap and hold), `AttackLifecycle` (one move's lifetime) and `Hitbox` (ShapecastHitbox wrapper) (§6.2). |
| `controllers/UIController/` | Auto-loads optional modules: `Hitmarker`, `WeaponMenu`, `HitHighlight`, `DamageIndicator`. |

### Tests (`tests`)

`RunTests.lua` (Studio only), `specs/*.spec.lua` (TestEZ), `support/` (`FakeClock`, `FakeRemote`, `FakeAnimationTrack`, `FakePlayers`, `FakeProfileStore`, `ServerHarness`) and `tools/BakeAnimationManifest.lua`. Specs build services through their public constructors with these fakes, and never use an infinite `WaitForChild`.

## 3. Boot and Runtime composition

### 3.1 Runtime

`Runtime.new(name)` then `rt:Add(name, factory)` for each service, then `rt:Start()`:

1. Each factory runs in `Add` order, receiving `get(name)`, which returns an earlier service and errors for one not yet built. A factory must return a table with `Destroy`.
2. `Start()` is then called on every built service that has one, in `Add` order.
3. If anything fails, the services already built are destroyed in reverse order (each in a pcall), and `"<rt>: failed to start <service>: <err>"` is raised.

`rt:Destroy()` tears down in reverse `Add` order. It is idempotent and warns on a failing `Destroy`.

### 3.2 Server

`init.server.lua` gathers `ServerEnv = { Players, Remotes, WeaponModels, IsStudio, Scheduler, Heartbeat, AnalyticsService }` and composes, in order:

| Order | Service | Player component |
| --- | --- | --- |
| 1 | `AssetContracts` (Content) | |
| 2 | `Telemetry` | |
| 3 | `PlayerService` | |
| 4 | `RemoteBudget` | yes (1st) |
| 5 | `PlayerDataService` | yes (2nd) |
| 6 | `InventoryService` | yes (3rd) |
| 7 | `WeaponService` | yes (4th) |
| 8 | `WeaponInbound` (InboundSink) | |
| 9 | `PositionHistory` | yes (5th) |
| 10 | `MovementValidation` | yes (6th) |
| 11 | `DamageService` | yes (7th) |
| 12 | `CombatFxService` | |
| 13 | `CombatFxInbound` (InboundSink) | |
| 14 | `CombatService` | yes (8th) |

Components register themselves in their constructors (`deps.players:Register(self, name)`), so the component order is the composition order. `PlayerService:Start()` connects `Players` events and then processes the players already in the server. The Runtime is destroyed when the script is destroyed.

### 3.3 Client

`init.client.lua` first runs `UiContracts.Report(UiContracts.Verify(Catalog, ReplicatedStorage.ui), IsStudio)`. It then builds the `"Client"` Runtime:

1. `Input`: `InputController.new()`.
2. `Combat`: `CombatClient.new({ remote = remotes.Combat, fx_remote = remotes.CombatFx })`.
3. `Loadout`: `LoadoutClient.new({ inventory_remote = remotes.Inventory, weapon_remote = remotes.Weapon })`.
4. `Preload`: `TrackCache.preload(TrackCache.collect_catalog())`, one background `ContentProvider:PreloadAsync` over every Catalog animation.
5. `UI`: `UIController.new(...)` inside a pcall. If it fails, a warning is printed and a null service is used, so gameplay still starts.
6. `Player`: `PlayerController.new({ player, input, combat, loadout, scheduler, create_character = CharacterController.new })`.

The session clients and the UI live for the whole session. Each character gets a `CharacterController`, which builds its own `"Character"` Runtime: `CharacterState`, `WeaponController`, `AnimationController`, `MovementController`, `ParkourController`, `CombatController`. It is torn down in reverse when `character.Destroying` fires (not `Trove:AttachToInstance`, which errors for an unparented character). The controller calls `SetWeapon(loadout.EquippedId)` at start and follows `loadout.EquippedChanged`.

## 4. Player session lifecycle (server)

`PlayerSession` holds `Player`, `UserId`, `Phase` (`"Loading" | "Ready" | "Leaving"`, written only by PlayerService), `Character`, `Trove` (dies with the session), `CharacterTrove` (new per character), and the `CharacterAdded` / `CharacterRemoving` signals. Component state is stored with `session:Set(component, state)`, read with `session:Get(component)` and removed with `session:Clear(component)`. A state with `Destroy` is destroyed when it is replaced or cleared, and when the session is destroyed. The character is released on `character.Destroying`.

**Join** (one `task.spawn` per player; ignored if the player has already left or already has a session):

1. Create the session (`Loading`) and fire `PlayerAdded`.
2. Call each component's `OnPlayerAdded(session)` in registration order, each in a pcall. A hook may yield (PlayerDataService does). A failure warns `[PlayerService] <name>.OnPlayerAdded failed ...`, counts `Lifecycle/ComponentFailed`, and does not stop the join. Only components whose hook returned are recorded as completed. If the session is `Leaving` after a hook, the join stops.
3. Set `Ready`, fire `PlayerReady`, then dispatch `OnCharacterAdded(session, character, CharacterTrove)` if a character exists.

**Character events** reach only completed components, and only while the session is `Ready`. `OnCharacterAdded` runs in registration order and `OnCharacterRemoving` in reverse.

**Leave** (`Players.PlayerRemoving`, or `PlayerService:Destroy`): set `Leaving`, fire `PlayerRemoving`, call `OnCharacterRemoving` (if the session was Ready and has a character) and then `OnPlayerRemoving` in reverse order for completed components, destroy the session, and call `telemetry:Forget(player)`. A component still yielding in `OnPlayerAdded` must notice `Leaving` itself when it resumes.

**Remote handlers** act only on `GetReady(player)` sessions. `RemoteBudget` is the exception: it charges any session.

## 5. Network protocol

### 5.1 Remotes and actions

Remotes live in `ReplicatedStorage.remotes`. Action names come from `shared/network/Protocol`. Every payload is untrusted on arrival, and both ends type-check it before use.

| Remote | Direction | Action and arguments |
| --- | --- | --- |
| `Combat` (RemoteEvent) | C→S | `Attack(move_id: integer)`: both the combo tap and the Heavy hold |
| | C→S | `HitStart(move_id: integer)` |
| | C→S | `HitStop(move_id: integer)` |
| | C→S | `Hit(move_id: integer, target: Model, hitpoint: Attachment, position: Vector3)` |
| | S→C | `AttackAccepted(move_id: integer, next_combo_move_id: integer)` |
| | S→C | `AttackRejected(move_id: integer?, next_combo_move_id: integer?)`: `move_id` is nil for a malformed request, and `next_combo_move_id` is nil when the player has no state or weapon |
| | S→C | `HitConfirmed(move_id: integer, target: Model)`: only when damage was actually applied |
| `CombatFx` (UnreliableRemoteEvent) | S→C | `Hit(victim: Model, source: Model?, weapon_id: string, move_id: integer, position: Vector3, amount: number)`, where `amount` is the health actually removed |
| `Inventory` (RemoteEvent) | C→S | `SelectSlot(slot: integer)`: `0` selects nothing, and selecting the selected slot toggles back to nothing |
| | C→S | `SelectUid(uid: string)`: at most `MaxItemIdLength` (64) characters; an unknown uid is ignored; toggles like `SelectSlot` |
| | S→C | `Changed(entries: { { Slot: integer, Uid: string, ItemId: string } }, selected_slot: integer)`: a dense array sorted by slot, with `0` for no selection |
| `Weapon` (RemoteEvent) | S→C | `Equipped(weapon_id: string)` |

Move ids are per weapon: the Catalog sorts move names and numbers them from 1, so Fists and Katana both have `Heavy = 1`, `Light1 = 2`, `Light2 = 3`. The server ignores a non-string action (counting `Network/BadPayload`) and any action it does not handle.

The client drops malformed messages: `CombatClient` requires integer ids, Models, a finite position and a finite amount; `LoadoutClient` requires a string weapon id and well-formed `{ Slot, Uid, ItemId }` entries.

### 5.2 Reply guarantees

- Every well-formed `Attack` that passes the budget gets exactly one `AttackAccepted` or `AttackRejected`, for combo and bound (Heavy) moves alike.
- A malformed or budget-dropped `Attack` gets at most one `AttackRejected` per `Combat.RejectReplyInterval` (0.25s), so a flood cannot be amplified into replies. The client also gives up on a pending attack after `Combat.PendingAttackTimeout` (1s).
- The client advances its combo only on `AttackAccepted` (or adopts the server's `next_combo_move_id` from a reject), and shows the hitmarker only on `HitConfirmed`.

### 5.3 RemoteBudget

`RemoteBudget:Take(player, "<Remote>.<Action>")` refills the player's action bucket and global bucket (`min(Burst, tokens + Rate * dt)`). It succeeds only if both hold a token, and then spends one from each. Budgets come from `Config.Network.RemoteBudget`:

| Key | Rate (/s) | Burst |
| --- | --- | --- |
| Global (per player) | 60 | 120 |
| `Combat.Attack` (combo and Heavy share it) | 12 | 3 |
| `Combat.HitStart` | 50 | 4 |
| `Combat.HitStop` | 50 | 4 |
| `Combat.Hit` | 60 | 16 |
| `Inventory.SelectSlot` | 12 | 3 |
| `Inventory.SelectUid` | 12 | 3 |

- A denied take counts `Network/RateLimited` with the action key.
- An unknown action spends a global token if one is left, returns false, and counts `Network/UnknownAction` with the detail `<Remote>.<unknown>`. The client's text never reaches analytics; Studio prints the raw name (truncated to 64 characters).
- There is no session, so false is returned.
- Bucket state is session state: it is not reset by respawns or weapon changes.

`InboundSink` listens on the server-to-client remotes `Weapon` and `CombatFx`. Each event a client fires at them is charged as `<Remote>.Inbound`, an unknown action, so it costs global budget and is counted. Otherwise the engine would queue the events and warn.

### 5.4 Telemetry

`Telemetry:Count(player, category, reason, detail?)`, with categories `Combat`, `Movement`, `Network`, `Lifecycle` and `Data`. Details are truncated to 48 characters, and each player keeps at most 64 distinct keys between flushes (the rest go under `<overflow>`). For the Combat, Movement and Network categories, a per-player suspicion score `v <- v * 0.5^(dt / HalfLife) + weight` is kept, with weights from `Config.Telemetry.Weights` (`Rewound` and `Blocked` weigh 0, `EarlyHitStart` 0.25, and unlisted reasons `DefaultWeight` = 1). Every `FlushInterval` (60s) it sends one `LogCustomEvent(player, "Reject_<Category>", count, { CustomField01 = reason, CustomField02 = detail })` per key, and in Studio prints one `[Telemetry] ...` summary line. `Forget` flushes a leaving player's counts, and `Destroy` does a final flush. Cooldown and out-of-sequence Attack rejects are not counted, because they happen in normal play.

## 6. Combat pipeline

### 6.1 Weapons and moves

A weapon definition (`src/shared/weapons/Fists.lua`, `Katana.lua`) has `Type = "Melee"`, `Model` (template name), `CanSprintWhileAttacking`, `Wield` (template part name to R6 body part), `Animations` (`Equip`, `Idle`, `Sprint`; a role reusing an earlier role's id must say `SharedWith`), `MoveDefaults` (shallow-merged into each move), `Moves`, `Combo` and `Bindings`.

A move (`Types.MoveDef`) has `Kind` (`"Light"` or `"Charge"`), `Animation`, `Hitbox` (a wield key or a template part), `Damage`, `Cooldown`, `MinDuration`, `HitStartAt`, `HitWindow`, `HitPositionTolerance`, `Range`, an optional `CanSprintWhileAttacking`, and `Hold = { HoldTime, MaxHoldTime }` if and only if it is a Charge.

`Validator.check` collects every error. Its rules: move names match `^%a[%w_]*$` and `Combo` is reserved; `Name` and `Id` are injected by the Catalog and forbidden in authored data; `Combo` lists one or more Light moves; `Bindings.Primary.Tap` is `"Combo"` or a move name; `Bindings.Primary.Hold` is an optional Charge move; every move is reachable; `Cooldown >= MinDuration`; `Hold.MaxHoldTime > HitStartAt`. `Catalog` serves the allowlist (Fists, Katana). On load it runs `Validator.check` and `AnimationContracts.check` for every weapon, raises all errors at once, and deep-freezes the definitions with `Id`, move `Name` and move `Id` injected. `Catalog.DefaultId = "Fists"` is the single source of the default weapon. `Catalog.Loadout("Starter")` is `{ [2] = "Katana" }`.

Current content (pinned by `WeaponGolden.spec`):

| Weapon | Move | Kind | Hitbox | Damage | Cooldown | MinDuration | HitStartAt | HitWindow | Tolerance | Range | Hold |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Fists | Light1 | Light | RightFist | 10 | 0.35 | 0.35 | 0.13 | 0.4 | 3 | 8 | |
| Fists | Light2 | Light | LeftFist | 10 | 0.35 | 0.35 | 0.13 | 0.4 | 3 | 8 | |
| Fists | Heavy | Charge | RightFist | 20 | 0.6 | 0.6 | 0.26 | 0.55 | 3 | 8 | 0.15 / 10 |
| Katana | Light1 | Light | Mesh | 15 | 0.6 | 0.6 | 0.38 | 0.45 | 3 | 10 | |
| Katana | Light2 | Light | Mesh | 15 | 0.6 | 0.6 | 0.4 | 0.4 | 3 | 10 | |
| Katana | Heavy | Charge | Mesh | 30 | 0.6 | 0.6 | 0.83 | 0.55 | 3 | 10 | 0.15 / 10 |

`HitStartAt` sits just under each animation's baked HitStart marker (`AnimationManifest`), so the server never opens a hit window before the swing does. A light move's `HitWindow` reaches its HitStop marker plus about 0.15s.

Both weapons use `Combo = { "Light1", "Light2" }` and `Bindings.Primary = { Tap = "Combo", Hold = "Heavy" }`.

### 6.2 Client side

- **Input.** `AttackInput` turns a Primary press into a tap or a hold. Released before the Hold move's `HoldTime`, it is a tap: the next combo move, `CombatController:Attack`. A tap during the cooldown is ignored. Held past `HoldTime`, it is the Hold move (Heavy). A hold that crosses `HoldTime` during the cooldown is buffered, and starts when the cooldown ends if Primary is still held.
- **Gates.** An attack starts only if no combo move is pending, the cooldown (`Cooldown`, anchored at the move start) has passed, the character is alive, and `CharacterState:CanStart("Attack")` (or `"Charge"`) allows it.
- **Lifecycle** (`AttackLifecycle`). It acquires an `Attack` lease (`AttackRooted` when the move or weapon cannot sprint while attacking), plays the move animation (role `"Move:<Name>"`), and sends `Attack(move_id)`. On the `HitStart` animation marker it starts the hitbox and sends `HitStart`. A Charge pauses on that marker while held, and the hit starts at the release (or automatically at `MaxHoldTime`). On the `HitStop` marker it stops the hitbox and sends `HitStop`. When the animation ends, the attack is finished, which also stops the hitbox and sends `HitStop` if they are still open, and releases the lease. The cooldown (`AttackReadyAt = start + Cooldown`) is anchored at the move's start.
- **Hitbox.** One ShapecastHitbox per equipped weapon and wielded part, created on first use and only started and stopped per move. It is destroyed on weapon swap, death or teardown. Hits resolve targets with `CharacterQuery.resolve_alive`, skip self and repeat targets, and are forwarded as `Hit(move_id, target, hitpoint, position)`.
- **Cancels.** The attack in flight is finished cleanly (HitStop sent, hitbox stopped, lease released, pending and buffered input dropped) on: a ledge grab (`CharacterState.Changed` reports `Hang` active), an Animator replacement (`AnimationController.CacheReset`), death, a weapon change, or teardown.

### 6.3 Server timing (`CombatService`, `MoveKinds`)

Per-session state: `{ Active, ComboIndex, NextAttackAt, ChargeReleasedAt, LastThrottledRejectAt }`. All times use `scheduler.clock()`. `TOL` is `Combat.TimingTolerance` (0.1s), which absorbs jitter between two packets from the same client.

**`Attack(move_id)`** is accepted when:

1. the player has a character and an equippable weapon;
2. `move_id` names a move of that weapon;
3. `now + TOL >= NextAttackAt`, the previous move's `MinDuration`, anchored at its start;
4. the move is the combo-expected move (the cursor advances and wraps) or is bound in `Bindings` (the Heavy; the cursor is untouched);
5. its wielded hitbox part is in the character.

Then `NextAttackAt = max(NextAttackAt, now + MinDuration)`, any previous active move is cleared, and a new active record is created with timing from `MoveKinds[move.Kind].create_timing`:

| Kind | `HitStartOpensAt` | `HitStartClosesAt` | `ExpiresAt` | Hit window after HitStart at `t` |
| --- | --- | --- | --- | --- |
| Light | `start + HitStartAt - TOL` | `start + HitStartAt + HitWindow + TOL` | = `HitStartClosesAt` | until `ExpiresAt` |
| Charge | `start + HitStartAt - TOL` | `start + MaxHoldTime + TOL` | `HitStartClosesAt + HitWindow` | until `min(ExpiresAt, t + HitWindow + TOL)` |

An expiry is scheduled at `ExpiresAt`. If a Charge was held past its marker, its release time is recorded (`ChargeReleasedAt`). The next Hold-bound move's `HitStartOpensAt` is then raised to at least `release + HoldTime + HitStartAt - TOL`, so two Heavies cannot land within a few frames. Weapon changes reset the combo cursor and clear the active move, but keep `NextAttackAt`. Character removal also clears `NextAttackAt` and `ChargeReleasedAt`.

**`HitStart(move_id)`** must match the active move:

- A second HitStart counts `Duplicate`.
- An invalid attacker counts `AttackerInvalid`; one after `HitStartClosesAt` counts `LateHitStart`. Both clear the move.
- A changed wielded part counts `WieldMismatch` and clears the move.
- **An early HitStart** (before `HitStartOpensAt`) counts `EarlyHitStart` and is **armed**: it activates at `HitStartOpensAt` exactly as an on-time one would.

**`Hit(...)`** while a HitStart is armed is **buffered** (the hit buffer): it is payload-checked (`CombatValidation.IsHitPayload`) and stored once per target, up to `MaxHitRequestsPerAttack`. A repeat target counts `Duplicate` and the excess counts `RejectLimit`. When the window opens, `_activate_pending` validates the buffered hits in arrival order through the normal path, and stops if one of them clears the move. A HitStop, expiry, respawn or attacker change drops the buffer.

**`Hit(...)`** in an open window is rejected as `Expired` after `HitExpiresAt` / `ExpiresAt` (clearing the move), or as `Duplicate` for a target already hit. It is dropped as `RejectLimit` once the target has failed `MaxRejectsPerTarget` (2) times, the move has hit `MaxHitsPerAttack` (8) targets, or it has received `MaxHitRequestsPerAttack` (12) hit packets. Otherwise it goes to validation (§6.4) and then damage (§6.6).

**`HitStop(move_id)`** clears the matching active move.

### 6.4 Hit validation (`CombatValidation.ValidateHit`)

`ValidateHit` returns `(humanoid, nil, rewound)` on success or `(nil, reason)`:

| Check | Reason |
| --- | --- |
| Malformed payload: target not a Model, hitpoint not an Attachment, non-finite position | `BadPayload` |
| Self-hit, target not in Workspace, target not its own `CharacterQuery.resolve` root, no live Humanoid, missing roots | `TargetInvalid` |
| The move's wielded part changed | `WieldMismatch` |
| Hitpoint not under the wielded hitbox part, or not tagged `Hitpoint` | `NoHitpoint` |
| Target root beyond `Range` (plus allowances) | `Reach` |
| Impact further than `HitPositionTolerance` from the target's bounding box | `OffBody` |
| Impact further than `Range + HitPositionTolerance` from the attacker (along its lead) | `Reach` |
| Target outside the horizontal facing cone (`MinFacingDot` = -0.25) | `Facing` |
| Line of sight from attacker root to target root (head to head as a fallback) is blocked. Both characters, non-collidable parts and up to `MaxLineOfSightCasts` (4) bystander characters are skipped | `NoLOS` |

### 6.5 Lag compensation

`PositionHistory` is a player component that writes one sample `{ Time, RootCFrame, BoxCFrame, BoxSize }` per live character each Heartbeat into a ring buffer of `HistoryCapacity` (64) entries, then fires `Stepped(now)`. `Sample(character, t)` interpolates and clamps to the oldest and newest samples. When `Reach` or `OffBody` fails against the target's current state, and `LagCompensation.Enabled` is on, both checks are retried against the target's sample at `Latest.Time - Rewind`, where `Rewind = clamp(GetNetworkPing() + InterpolationDelay (0.1), 0, MaxRewind (0.3))`. The attacker is compensated the other way: its server-observed velocity (from its own `PositionHistory` samples over the last 0.1s, capped at `MaxAttackerSpeed` (40 studs/s)) times the same `Rewind` window gives a lead vector. Reach, for both the target's root and the reported impact, is measured from anywhere along the attacker's root plus that lead. The impact is not compared with the server's copy of the weapon hitpoint: swing animations play on the client and the server's pose of the arm and weapon does not follow them, so that comparison rejected real hits by up to the weapon's length (`HitpointOffset` is no longer produced). A stationary attacker gets no lead. This stops running attacks from being rejected because the server holds the attacker a few studs behind where its client swung. The line-of-sight casts shift the target root and head by the rewound offset. A hit that passes only this way is counted as `Combat/Rewound`. Rewind can only make validation more lenient. Studio's zero ping rewinds by `InterpolationDelay` only.

### 6.6 DamageService and FX

`DamageService:Apply(request)` is the only caller of `Humanoid:TakeDamage`. Its request is `{ Source = { Model, Player? }, Target, Amount, Kind = "Melee", WeaponId, MoveId, Position }`.

1. `IsDamageable`: a live Humanoid (via `CharacterQuery`) that is a player character, carries the `Damageable` tag, or is any Humanoid while `AllowUntaggedHumanoidTargets` is true.
2. Ordered policies may reduce the amount. The built-ins are `Invulnerable` (the attribute), `SpawnProtection` (`SpawnProtectionSeconds`, currently 0, so off) and `Team` (blocks same-team, non-neutral players while `FriendlyFire` is false). `AddPolicy(name, fn)` appends more; a duplicate name errors.
3. `TakeDamage`, then `applied` = the health actually removed (0 under a ForceField).

`Apply` returns `(applied, reason)`, where `reason` is a policy name, `NotDamageable`, `InvalidRequest` or `NoEffect`. It fires `Damaged(request, applied, health_after)`, and `Killed(request, assists)` with the recent attackers (`RecentAttackerCount` = 5 within `RecentAttackerWindow` = 15s). The recent attackers of a target are forgotten when it leaves the DataModel. CombatService sends `HitConfirmed` only when `applied > 0`; otherwise it counts `Blocked`.

`CombatFxService` handles `Damaged` with `applied > 0`. It fires `CombatFx.Hit` to the victim's player (while Ready) and to every Ready player whose root is within `Fx.RelevanceRadius` (120 studs) of the impact. On the client, `CombatClient.FxHit` drives `HitHighlight` (a pooled Highlight on the victim for 0.12s, no template), and `CombatClient.Damaged` (when the victim is the local character) drives `DamageIndicator` (the optional `DamageIndicator` template's `Flash` for 0.15s).

## 7. Parkour

Parkour is client-authoritative and lives in `ParkourController/`. The server only observes the result.

### 7.1 State machine (`ParkourController/State.lua`)

The controller holds exactly one `ParkourState`. Its per-state data cannot exist without that state:

| Kind | Data |
| --- | --- |
| `Grounded` | `TopHop: TopHopData?` (`StartedAt`, `SawAir`) |
| `Hanging` | `HangData`: climbable, normal, hang offset and position, corner lock |
| `Mantling` | `MantleData`: start and target CFrames, elapsed time, duration |
| `Vaulting` | `VaultData`: exit velocity, start and target, elapsed time, duration, arc height and peak, obstacle |

Allowed transitions: Grounded → Grounded, Hanging, Vaulting; Hanging → Hanging, Grounded, Mantling; Mantling → Mantling, Grounded, Hanging; Vaulting → Vaulting, Grounded. `State.enter(ctrl, next)` checks the table, acquires the incoming state's lease and Humanoid overrides **before** releasing the outgoing state's (so a Hang → Mantle hand-off never briefly unblocks an action), then installs the new state in one assignment. Accessors: `State.kind`, `hang`, `mantle`, `vault` and `top_hop`; `State.reset` returns to Grounded. Leases held: `Hang`, `Mantle`, `Vault`, and `TopHop` (until landing or timeout).

Around it:

- `InputLatch`: `Forward` and `Jump` latches that stay blocked until the key is released. Override handles can be attached to a latch, so the disabled jump after a mantle or vault lasts until Space is released.
- `Queries` and `LedgeDetection`: candidate search and classification.
- `LedgeTraversal` and `Traversal`: hang, shimmy and corners. The corner fan's miss is cached for `CornerProbeMissTtl` (0.2s) while traversal is blocked.
- `VaultTraversal` and `VaultMath`: vault, and the top-hop onto a raised surface. The top-hop pushes `JumpPower = 0` (or `JumpHeight`) until the Humanoid leaves `Jumping`.
- `QueryContext`: owns every `RaycastParams` and `OverlapParams`, and routes every Workspace query (`Raycast`, `Pierce`, `PartsInPart`, `PartBoundsInBox`) through one place that records metrics.
- `Metrics`: ray counters. Rays cast inside `measure_search` (the one-off Mantle and LowerLedge searches, which scan a 7x6 column grid per guide on a key press) count toward that search's `SearchRayBudget` (256). Every other ray counts toward the steady per-frame `FrameRayBudget` (48). In Studio each budget warns at most once per `BudgetWarnInterval` when exceeded.

### 7.2 CharacterState arbiter (`CharacterState/`)

Controllers hold **leases** on activities (`Attack`, `AttackRooted`, `Hang`, `Mantle`, `Vault`, `TopHop`, `Stunned`) and ask `CanStart(action)` for the actions `Attack`, `Charge`, `Sprint`, `Vault` and `Grab`. `Changed(activity, active)` fires on an activity's first acquire and last release. `Policy.lua` (client-side, because only client code consults it):

| Activity | Blocks |
| --- | --- |
| `Attack` | nothing (a ledge grab cancels the attack) |
| `AttackRooted` | Sprint |
| `Hang` | Attack, Charge, Sprint, Vault |
| `Mantle`, `Vault`, `Stunned` | Attack, Charge, Sprint, Vault, Grab |
| `TopHop` | Vault |

MovementController sprints only while Sprint is held, `MoveDirection` is at least `SprintMinMoveMagnitude`, and `CanStart("Sprint")` allows it, and it re-evaluates on `Changed`. ParkourController checks `CanStart("Vault")` and `CanStart("Grab")`. CombatController checks `CanStart("Attack")` / `CanStart("Charge")`, and cancels its attack when `Hang` becomes active.

### 7.3 HumanoidOverrides

`state:Overrides(humanoid)` returns one memoised stack set per Humanoid, for `AutoRotate`, `PlatformStand`, `HipHeight`, `JumpPower`, `JumpHeight` and `JumpingEnabled` (which maps to `SetStateEnabled(Jumping)`). `Push(owner, props)` returns a handle, `handle:Set` changes a pushed property, and `handle:Pop()` is idempotent. The effective value is the most recent live handle's value. The base value is captured when a property's stack goes from empty to non-empty and written back when it empties, but only if the Humanoid is still parented. `WalkSpeed` is not managed here: MovementController is its only writer, and it writes only on change. `CharacterState:Destroy()` releases every lease and pops every override.

### 7.4 ClimbableIndex

`ClimbableIndex.get()` is a module singleton that survives respawns. It is built over CollectionService's `Climbable` tag (`Config.World.Tags.Climbable`) with a 16-stud spatial hash, and indexes only descendants of Workspace. Guides are tracked through the tag's added and removed signals and per-guide ancestry. A guide spanning more than 512 cells goes in a flat list.

- `QueryBox(cframe, size)`: guides whose cached world AABB overlaps the box.
- `GuideOf(instance)` / `IsClimbable(instance)`: the nearest tagged ancestor, by set membership.
- `Bounds(guide)`: the guide's box.

Bounds are cached and re-measured when they go stale:

- a BasePart on CFrame or Size change;
- a static Model when its pivot or its reference part's CFrame changes (checked on every query);
- a Model containing an unanchored part, or with the `ClimbableDynamic` attribute, live on every query.

The `Climbable` collision group alone does not make a part climbable.

## 8. Items and persistence

- **Items.** `ItemCatalog` holds `Katana = { Kind = "Weapon", WeaponId = "Katana", Stackable = false }`. At load it checks that each `WeaponId` is equippable and is not the default weapon, and that every Starter-loadout weapon has an item.
- **Profile schema v1** (`shared/data/Schema.lua`): `{ Version = 1, Inventory = { Slots = { ["<slot>"] = { Uid, ItemId, Data } }, Seeded = boolean } }`. Slot keys are strings, so the saved data has no sparse arrays. The selection is not persisted.
- **Migrations.** `Schema.Migrations[n]` upgrades version n to n+1 in place (empty at v1). `Schema.run_migrations(data, migrations, target)` refuses a missing, invalid or newer `Version`. `Schema.validate` checks the top-level shape. `Schema.migrate` is `run_migrations` followed by `validate`.
- **Sanitising.** `Schema.sanitize(data)` drops only structurally corrupt slots: a key that is not an unpadded positive integer, a malformed record, or a Uid repeated from a lower slot. It returns one warning per dropped slot. Records with an ItemId this build does not know, or in a slot above `MaxSlots`, are **kept** (they may come from a newer build). InventoryService does not replicate or equip them, but their slot stays occupied.

**PlayerDataService** (the first data component) runs `OnPlayerAdded` like this:

1. `StartSessionAsync("Player_<UserId>", { Cancel = Phase == "Leaving" })`. If the player left meanwhile, the profile is released.
2. The migrations run on a deep copy. A refused profile is released exactly as saved, and the load fails.
3. The upgraded copy is installed, then `AddUserId` and `Reconcile` run, then `validate`, `sanitize` (each warning counts `Data/Sanitized`), and the Starter seed (once, `Seeded = true`: the Katana in slot 2).
4. A failure after the session started releases the profile.
5. `OnSessionEnd` while the player is still in game, and the server is not closing, means another server took the lock. That counts `Data/SessionEnded` and kicks with "Your data was opened on another server."

A load failure counts `Data/LoadFailed`. On a live server it kicks with "Your data failed to load. Please rejoin."; in Studio it warns and continues on an unsaved in-memory template. `OnPlayerRemoving` ends the session. `compose/Items` creates `ProfileStore.New(Config.Data.StoreName, Schema.Template())`. In Studio with `Config.Data.UseMockInStudio` (the default) it uses `store.Mock`, given a metatable exposing `IsClosing`, and warns once that data is not saved. ProfileStore binds `BindToClose` itself and falls back to its own mock without API access.

**InventoryService** (needs loaded data; a player without it gets no inventory):

- API: `Get`, `GetSelected`, `GetSelectedSlot`, `GetEquippedWeaponId` (the selected item's weapon, or `Catalog.DefaultId`), `Grant(player, item_id, slot?)` (returns the new uid from `HttpService:GenerateGUID`, or nil if the slot is taken), `RemoveUid`, `SelectSlot` and `SelectUid`.
- `Changed(player, weapon_id, selected_slot)` fires for Ready sessions only.
- Slots are integers in `1..Config.Inventory.MaxSlots` (9).

**WeaponService** equips `inventory:GetEquippedWeaponId`:

- It caches one model per weapon per character. An unequipped model is parented to nil and re-parented when equipped again.
- It coalesces equips: the first request applies at once, and later requests within `EquipCoalesceWindow` (0.2s) apply the latest id when the window ends.
- It warns once per weapon id about a missing template, and sends `Weapon.Equipped`.
- `WeaponAttachment` welds the `Wield` parts with Motor6Ds to the R6 arms, sets every weapon part to `CanCollide = false` and `CanQuery = false` (so casts pass through weapons to bodies), and tags `Hitpoint` attachments. It refuses non-R6 rigs.

On the client, `LoadoutClient` exposes `SelectSlot`, `SelectUid` and `SelectWeapon(weapon_id)` (the first entry for that weapon, or `SelectSlot(0)` for the default weapon). PC hotkeys 1–9 select slots 1–9.

## 9. Asset contracts and the animation manifest

### 9.1 Boot checks

- **Server, `AssetContracts.Verify(Catalog, weapon_models)`**, composed first. It checks that the folder exists; that every Catalog weapon has a template named after its `Model` (a BasePart, or a Model containing one); that every `Wield` key resolves to a BasePart; that every move `Hitbox` resolves (as a wield key first, then anywhere) to a BasePart with a descendant `Hitpoint` Attachment; and that each hitbox is a wield part or is connected to one through `WeldConstraint`, `RigidConstraint` or `JointInstance` links inside the template. `Report` errors in Studio (the boot stops: `Server: failed to start AssetContracts: ...`) and warns per problem on live servers.
- **Client, `UiContracts.Verify(Catalog, ui)`.** Every `GuiButton` with a `WeaponId` attribute in the `WeaponMenu` template must name a Catalog weapon. A missing template is not an error. It is reported the same way.
- `RuntimeContracts.spec` reuses both checks per weapon.

### 9.2 Animation manifest

`src/shared/weapons/AnimationManifest.lua` maps `"rbxassetid://N"` to `{ Length, Markers = { HitStart?, HitStop? } }`. It is **empty until baked**. For each move whose animation has an entry, `AnimationContracts.check` requires:

- `HitStartAt <= Markers.HitStart + 1ms`;
- for a Light move, `HitStartAt + HitWindow >= Markers.HitStop`;
- `MinDuration <= Length`;
- for a Charge move, a `HitStart` marker.

Ids without an entry are not checked. `tests/tools/BakeAnimationManifest.lua` generates the module in Studio (steps in [DEPENDENCIES.md](DEPENDENCIES.md#animation-manifest)). The Katana light `MinDuration` of 0.6s must fit within those animations' lengths once baked.

## 10. Tooling

- **Aftman / Rokit** (`aftman.toml`) pin `rojo` 7.7.0, `luau-lsp` 1.70.1, `selene` 0.32.0 and `wally` 0.3.2.
- **Wally** (`wally.toml`, package `shylocal/project-nullrise`): `sleitnick/trove@1.8.0` and the dev dependency `roblox/testez@0.4.1`, installed into the git-ignored `Packages/` and `DevPackages/`. Run `~/.rokit/bin/wally install` before `rojo serve` or `rojo build`.
- **`sh scripts/analyze.sh`** is the gate. It installs Wally packages if they are missing, fetches the Roblox type definitions into `.luau/`, regenerates `sourcemap.json`, and runs `luau-lsp analyze` (Roblox platform, TestEZ defs; vendored code and packages ignored). It then runs `selene src tests` (`std = "roblox+testez+luau_extras"`; `roblox.yml` is generated locally). It must report zero luau-lsp diagnostics and zero selene findings.
- **Build:** `rojo build default.project.json -o <out>.rbxlx`.
- **Tests:** TestEZ in Studio only, with `require(game:GetService("TestService").RunTests).Run()` ([TESTING.md](TESTING.md)).
- **No CI**, on purpose.

---

## History

The current architecture came out of a three-phase refactor on `main`, driven by a ranked review of 20 items (R1–R20, `docs/refactor/REVIEW_IDEAS.md`). Its design contract was `docs/REFACTOR_PLAN.md`; the full text, including the per-agent file ownership and the complete deviation log, is in git history (`git show 973df88:docs/REFACTOR_PLAN.md`). The handoff log is `docs/refactor/HANDOFF.md`.

**Phases**

- **Phase 1, foundations:** the config tree and Envelope, Freeze and Schema; Catalog as the single source of weapons; CharacterQuery; the Protocol split; Runtime, Scheduler and Deps; PlayerService and PlayerSession components; RemoteBudget and Telemetry with reason codes. On the client: session clients and composition, TrackCache, the parkour state machine, InputLatch, ClimbableIndex, QueryContext, the CharacterState arbiter and HumanoidOverrides. Test fakes.
- **Phase 2, features:** weapon schema v2 (Moves, Combo, Bindings) and the move-id wire; MoveKinds; DamageService and CombatFx; PositionHistory lag compensation and armed early HitStarts; ItemCatalog, profile Schema v1 and ProfileStore persistence; WeaponService model caching and equip coalescing; asset, UI and animation contracts; selene; Wally for Trove and TestEZ.
- **Phase 3, strict typing:** `--!strict` everywhere, exported class and `Deps` types, structural `*Like` interfaces for client collaborators, `ClientTrove`, dead-code removal, and the early-HitStart hit buffer.
- **Review and Finish:** an adversarial review (`docs/refactor/REVIEW_FINDINGS.md`) found 10 issues, none critical or high. All are fixed. Then two user decisions (ledge grab cancels an attack; slower light-attack cooldowns), and this document.

**Notable deviations from the plan**

- R9's policy table lives client-side (`CharacterState/Policy.lua`). R18's default weapon id is folded into `Catalog.DefaultId`.
- ProfileStore is vendored server-only under `src/server/vendor/`. Signal and ShapecastHitbox stay vendored; Trove and TestEZ come from Wally.
- `ServerHarness`, `InboundSink`, `compose/Remotes` and `ClientTrove` were added. Session state is typed `unknown` and cast by its owner, and server troves are `any`.
- Telemetry details are bounded (48 characters, 64 keys per player). Cooldown and out-of-sequence rejects are not counted. `Rewound`, `Blocked` and `EarlyHitStart` carry low or zero suspicion weight.
- `DamageService` reports the health actually removed, so a ForceField yields no hitmarker.
- `ClimbableIndex` treats unanchored parts as dynamic and re-measures moved Models. `State.enter` acquires the new state's resources before releasing the old ones.

**Intentional behaviour changes** (numbering kept from the plan's §14; other docs cite them as "§14.N")

1. Hits on an enemy's weapon resolve to the enemy: weapon parts are `CanQuery = false`.
2. Malformed or budget-dropped Attack requests get at most one `AttackRejected` per 0.25s. Hit packets are budgeted (60/s, burst 16); Attack, HitStart and inventory requests allow small bursts.
3. The Heavy (Charge) gets `AttackAccepted` / `AttackRejected` replies.
4. Attacks cannot start while hanging, mantling or vaulting.
5. The movement observer's horizontal limit moved from 96 to 98.5 studs/s (derived by Envelope).
6. PC hotkeys 3–9 select slots 3–9.
7. The corner fan is cached for 0.2s while traversal is blocked.
8. Early HitStarts are armed instead of dropped, and validation is lag-compensated (only ever more lenient).
9. Hit FX: a highlight on the victim for nearby players, and a damage flash for the victim if its template exists.
10. Inventory persists across sessions; Studio uses the mock store by default.
11. Damage policies exist but are no-ops with current content; untagged Humanoids stay valid targets.
12. Remote budget state is not reset on respawn.
13. Hanging on a MeshPart, WedgePart or Union guide and pressing A/D no longer errors every frame.
14. Hits that arrive while an early HitStart is armed are buffered and validated when the window opens.
15. Moved Climbable Models are re-measured, and Models with unanchored parts are measured live (review finding 8).
16. An Animator replacement mid-attack finishes the attack at once (review finding 9).
17. After a window focus loss, the first Left Shift press sprints again (review finding 10).
18. After a Heavy held past its marker is released, the next Hold-bound move's hit cannot open before `release + HoldTime + HitStartAt - TimingTolerance` (review finding 1).
19. Load-time sanitising keeps records this build does not recognise, and refused or failed profiles are released untouched (review findings 2–4).
20. UnknownAction telemetry no longer carries client text, and events fired at server-to-client remotes are drained and budgeted (review findings 5–6).
21. A ledge grab can start during a light attack or a Heavy charge, and it cancels that attack (user decision 1).
22. Light-attack cooldowns are slower: Fists 0.3 → 0.35s, Katana 0.35 → 0.6s, for both `Cooldown` and the server `MinDuration` (user decision 2).
