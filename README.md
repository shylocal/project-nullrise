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
│   │   ├── AnimationController/
│   │   │   ├── Combat.lua
│   │   │   ├── Movement.lua
│   │   │   ├── Weapon.lua
│   │   │   └── init.lua
│   │   ├── CombatController/
│   │   │   ├── AttackInput.lua
│   │   │   ├── AttackLifecycle.lua
│   │   │   ├── Hitbox.lua
│   │   │   └── init.lua
│   │   ├── ParkourController/
│   │   │   ├── ClimbableQuery.lua
│   │   │   ├── Config.lua
│   │   │   ├── LedgeTraversal.lua
│   │   │   ├── Metrics.lua
│   │   │   ├── Queries.lua
│   │   │   ├── State.lua
│   │   │   ├── Traversal.lua
│   │   │   ├── VaultMath.lua
│   │   │   ├── VaultTraversal.lua
│   │   │   └── init.lua
│   │   ├── UIController/
│   │   ├── CharacterController.lua
│   │   ├── InputController.lua
│   │   ├── MovementController.lua
│   │   ├── PlayerController.lua
│   │   └── WeaponController.lua
│   ├── input/
│   │   ├── Gamepad.lua
│   │   ├── Mobile.lua
│   │   └── PC.lua
│   └── init.client.lua
├── server/
│   ├── services/
│   │   ├── CombatService.lua
│   │   ├── CombatValidation.lua
│   │   ├── InventoryService.lua
│   │   ├── PlayerService.lua
│   │   ├── MovementValidation.lua
│   │   ├── PlayerSession.lua
│   │   ├── WeaponAttachment.lua
│   │   └── WeaponService.lua
│   └── init.server.lua
└── shared/
    ├── input/Actions.lua
    ├── movement/Config.lua
    ├── network/Protocol.lua
    ├── utility/Vector.lua
    └── weapons/
        ├── Catalog.lua
        ├── CombatConfig.lua
        ├── Fists.lua
        ├── Katana.lua
        └── Validator.lua
tests/
├── RunTests.lua
├── TestEZ/          (vendored test runner, mapped to TestService)
└── specs/
```

Vendored third-party packages live in `src/packages` (runtime) and `tests/TestEZ` (tests only); see [docs/VENDORED.md](docs/VENDORED.md).

## Runtime dependencies

Rojo now declares the expected containers so the place layout is visible in source:

- `ReplicatedStorage.packages`
- `ReplicatedStorage.ui`
- `ServerStorage.weapon_models`

Their required contents are documented in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md). The authored UI and weapon templates remain external assets; the source tree intentionally does not invent replacement art.

The server registers the required `Climbable` collision group during startup.

## Combat rules

The server validates attack sequencing, attack rate, active hit windows, current character/weapon ownership, target Humanoids, mandatory hitpoint attachments, impact positions, facing, range, and line of sight before applying damage.

- **Per-attack timing.** Every attack and charge in `src/shared/weapons/*.lua` defines `HitStartAt`, `HitWindow` and `MinDuration` (charges also `MaxHoldTime` and `HoldTime`). The server ignores a `HitStart` earlier than `HitStartAt`, rejects hits after the window closes, and rejects a new Attack/Charge before the previous one's `MinDuration`. A charge's hit window starts at its release, and the client releases it automatically at `MaxHoldTime`. `Cooldown` (client-side) must be at least `MinDuration`. Network jitter allowance and the client's pending-attack timeout live in `src/shared/weapons/CombatConfig.lua`.
- **Definitions are validated at load.** `Catalog` only serves the allowlisted weapons (Fists, Katana) and errors on startup if one is missing or fails `Validator`.
- **Line of sight** is always checked from the attacker's root to the target's root (head to head as a fallback). Both characters, non-collidable parts and up to four bystander characters are ignored; anything else blocks the hit. The reported impact must be within `HitPositionTolerance` of the target's bounding box and of the weapon hitpoint.
- **Every Attack request gets exactly one reply**, `AttackAccepted` or `AttackRejected` (including rate-limited or malformed requests). The client also drops a pending attack after `PendingAttackTimeout`, and resets it on death and weapon swaps.

Weapon changes reset combo sequencing but do **not** reset attack cooldown or per-remote rate-limit state. Player/character teardown clears all player-scoped combat state.

The client does not advance its combo until the server sends `AttackAccepted`, and the hitmarker only fires after `HitConfirmed`.

## Inventory

`InventoryService` holds up to `InventoryService.MAX_SLOTS` (9) slots and validates every slot index and item id. `Inventory.Changed` is sent as `(entries, selected_slot)`, where `entries` is a dense array of `{ Slot, WeaponId }` sorted by slot and `selected_slot` is an integer (`0` means nothing is selected, i.e. Fists). `PlayerController` is the only client listener and forwards the state to the UI.

## Movement validation

Movement is client-authoritative. `MovementValidation` on the server only observes and logs: it judges total displacement over a sliding window of up to 1 second (at least 0.25 seconds of samples), with a downward-speed bound that grows with the height fallen. See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## Input

PC, touch, and gamepad adapters all feed `InputController`. Logical actions are de-duplicated by device family and physical source. Mobile includes the actions needed by parkour; gamepad has an explicit adapter.

## Tests

TestEZ specs live under `tests/specs` and are mapped into `TestService`, together with the vendored TestEZ runner (`tests/TestEZ`), so the test runner is not shipped to clients. The suite is intentionally run from Studio because several tests instantiate Roblox objects and the repository does not bundle Roblox Studio.

See [docs/TESTING.md](docs/TESTING.md) for setup and the current coverage boundary.

## Tooling

Aftman pins the Rojo version used for local development. There is no CI workflow (it was removed); run the build and the Studio test suite locally.

```sh
aftman install
rojo build default.project.json -o build/project.rbxl
```

Run the live game with:

```sh
rojo serve
```

## Configuration

Parkour tuning belongs in `src/client/controllers/ParkourController/Config.lua`. Avoid inline fallback defaults in traversal code; configuration values should have one source of truth.

Current vault values include a 13.5-stud maximum vault distance (`VaultMaxOverDistance`, the only vault distance cap), 2-stud landing gap, 12 studs/sec forward boost, 45% physical-exit progress, 8 studs/sec top-hop boost, and a 0.95 duration multiplier.

Shared movement speeds live in `src/shared/movement/Config.lua`. `MovementController` applies `WalkSpeed`/`SprintSpeed` to the Humanoid (it does not adopt the Humanoid's own WalkSpeed), and holding Sprint only sprints while `Humanoid.MoveDirection` is at least `SprintMinMoveMagnitude`, so standing still never sprints or vaults.

Use comments for invariants and constraints, not patch history or session notes.
