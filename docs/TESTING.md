# Testing

The automated suite uses TestEZ and Roblox Studio. The repository does not run tests during game startup.

## Static checks

From the repository root:

```sh
aftman install
rojo build default.project.json -o build/project.rbxl
stylua --check src tests
selene src tests
```

These checks validate project structure, formatting, and static analysis. They do not execute Roblox physics or multiplayer networking.

## Studio TestEZ run

Populate `ReplicatedStorage.packages.TestEZ` using the pinned TestEZ package documented in `docs/DEPENDENCIES.md`, then start:

```sh
rojo serve
```

In Roblox Studio, connect the Rojo plugin to the server and start a local Play session. In a Server-context Command Bar:

```lua
require(game:GetService("TestService").RunTests).Run()
```

`tests/RunTests.lua` refuses to run outside Studio.

## Coverage boundary

Specs cover pure vector/vault math, configuration invariants, input aggregation, movement/controller state, weapon catalog and attachment contracts, protocol identifiers, combat validation/lifecycle rules, inventory validation/replication, attack callback ownership, and parkour lifecycle/snapshot behavior.

The suite intentionally does not prove real map traversal, animation asset availability, replicated physics, published-server networking, or adversarial client movement.

## Combat cases that must stay regression-tested

- Missing `Hit` segment or impact position is rejected.
- A valid hit must pass target/range, facing, hitpoint, and obstruction checks.
- Weapon changes reset combo sequence without clearing cooldown or remote rate-limit timestamps.
- Player removal clears every player-scoped combat table entry.
- Multiple targets can be reported during one hit window, subject to the per-target dedupe and per-attack cap.
- A hitmarker is emitted only after the server confirms damage.

## Manual gameplay smoke tests

After changes to combat, inventory, input, or parkour, exercise at least:

- attack through a wall and with missing hit arguments; neither should deal damage
- two valid targets in consecutive frames
- rapid slot alternation while an attack cooldown is active
- weapon swapping during an attack and while the cooldown is active
- character death/reset during a swing
- touch controls for Jump/Forward/Backward/Left/Right
- gamepad primary/jump/sprint and parkour direction controls
- R15 character startup (it should be rejected because the game requires R6)
- a climbable surface using the `Climbable` collision group/tag
- vault, mantle, and ledge release/reset cleanup