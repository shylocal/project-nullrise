# project-nullrise

A Roblox game built with native Luau and Roblox primitives.

## Development model

- **Rojo** is the source-to-place sync/build tool.
- **Trove** owns disposable connections, instances, and controller/service lifetimes.
- **Signal** is used for in-process events.
- **Combat is server-authoritative.** Client reports are untrusted input to a server validation boundary.
- **Parkour/movement are client-authoritative prototype systems.** See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for the deliberate security boundary.
- **R6 is the supported character rig.** Character startup rejects other rig types.

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
        ├── Fists.lua
        └── Katana.lua
```

## Runtime dependencies

Rojo now declares the expected containers so the place layout is visible in source:

- `ReplicatedStorage.packages`
- `ReplicatedStorage.ui`
- `ServerStorage.weapon_models`

Their required contents are documented in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md). The authored UI and weapon templates remain external assets; the source tree intentionally does not invent replacement art.

The server registers the required `Climbable` collision group during startup.

## Combat rules

The server validates attack sequencing, cooldowns, active hit windows, current character/weapon ownership, target Humanoids, mandatory hitpoint attachments, impact positions, facing, range, and line of sight before applying damage.

Weapon changes reset combo sequencing but do **not** reset attack cooldown or per-remote rate-limit state. Player/character teardown clears all player-scoped combat state.

The client does not advance its combo until the server sends `AttackAccepted`, and the hitmarker only fires after `HitConfirmed`.

## Input

PC, touch, and gamepad adapters all feed `InputController`. Logical actions are de-duplicated by device family and physical source. Mobile includes the actions needed by parkour; gamepad has an explicit adapter.

## Tests

TestEZ specs live under `tests/` and are mapped into `TestService`. The suite is intentionally run from Studio because several tests instantiate Roblox objects and the repository does not bundle Roblox Studio.

See [docs/TESTING.md](docs/TESTING.md) for setup and the current coverage boundary.

## Tooling

Aftman pins Rojo, StyLua, and Selene. `.stylua.toml` and `selene.toml` are checked into the repository. GitHub Actions builds the Rojo project and runs the static toolchain checks.

```sh
aftman install
rojo build default.project.json -o build/project.rbxl
stylua --check src tests
selene src tests
```

Run the live game with:

```sh
rojo serve
```

## Configuration

Parkour tuning belongs in `src/client/controllers/ParkourController/Config.lua`. Avoid inline fallback defaults in traversal code; configuration values should have one source of truth.

Current vault values include a 26-stud maximum hop distance, 2-stud landing gap, 12 studs/sec forward boost, 45% physical-exit progress, 8 studs/sec top-hop boost, and a 0.95 duration multiplier.

Use comments for invariants and constraints, not patch history or session notes.
