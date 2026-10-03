# Testing

The automated suite uses TestEZ and Roblox Studio. The repository does not run tests during game startup.

## Static checks

From the repository root:

```sh
aftman install
rojo build default.project.json -o build/project.rbxl
```

The build check validates project structure but does not parse or type-check Luau, and does not execute Roblox physics or multiplayer networking. There is no CI workflow; run these checks locally.

## Studio TestEZ run

TestEZ is vendored in `tests/TestEZ` (see `docs/VENDORED.md`) and Rojo maps it to `TestService.TestEZ`, next to `RunTests` and `specs`. Nothing needs to be installed. Start:

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
- A valid hit must pass target/range, facing, hitpoint, impact-on-target, and line-of-sight checks; a wall between attacker and target blocks the hit even when the hitpoint-to-impact segment is clear.
- Every `Attack` request is answered with exactly one `AttackAccepted` or `AttackRejected`, including rate-limited and malformed requests.
- A new attack before the previous attack's `MinDuration` is rejected, and an early `HitStart` (before `HitStartAt`) is ignored.
- A charge held up to its `MaxHoldTime` still deals damage after release.
- Weapon changes reset combo sequence without clearing cooldown or remote rate-limit timestamps.
- Player removal clears every player-scoped combat table entry.
- Multiple targets can be reported during one hit window (including on the same frame), subject to the per-target dedupe and per-attack caps.
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
- R15 character startup (the client warns and skips character setup, and the server refuses to arm the character; set Avatar Type to R6 in Game Settings)
- a climbable surface tagged `Climbable` (CollectionService tag; the `Climbable` collision group alone is ignored)
- holding Sprint while standing still (no sprint animation, no vault on Space)
- a long fall (no `MovementValidation` warning)
- respawning keeps the weapon menu and hitmarker working
- vault, mantle, and ledge release/reset cleanup
