# Testing

The automated suite uses TestEZ and Roblox Studio. The repository does not run tests during game startup.

## Static checks

From the repository root:

```sh
aftman install
rojo build default.project.json -o build/project.rbxl
```

The build check validates project structure but does not parse or type-check Luau, and does not execute Roblox physics or multiplayer networking.

`sh scripts/analyze.sh` type-checks and lints `src` and `tests` with luau-lsp (Roblox types plus a Rojo sourcemap it regenerates). It must report zero diagnostics. There is no CI workflow; run these checks locally.

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
- Every well-formed `Attack` request that passes the remote budget is answered with exactly one `AttackAccepted` or `AttackRejected`; malformed or budget-dropped requests get at most one `AttackRejected` per `RejectReplyInterval`.
- A new attack before the previous attack's `MinDuration` is rejected, and an early `HitStart` (before `HitStartAt`) is ignored.
- A charge held up to its `MaxHoldTime` still deals damage after release.
- Weapon changes reset combo sequence without clearing cooldown or remote budget state.
- Player removal clears every player-scoped combat state (it lives on the `PlayerSession`).
- A target that failed validation `MaxRejectsPerTarget` times is ignored for the rest of the attack.
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

## Refactor (Phase 1) smoke tests

These cover the intentional behaviour changes in `docs/REFACTOR_PLAN.md` §14 and the risks the Phase 1 agents could not check outside Studio. Run them in a Play session (two players where noted).

Server, network and telemetry:

- Spam `Attack` with a bad index (or past the budget) from a client: the client receives at most one `AttackRejected` per 0.25s, and the server stays responsive.
- Hit an enemy who is holding a Katana so that your swing passes through their blade first: the hit lands on the body (weapon parts are `CanQuery = false`) and deals damage.
- Sprint, vault and top-hop at full speed for a while: no `MovementValidation` warning (the horizontal limit is now 98.5 studs/s).
- Respawn repeatedly while attacking: the remote budget is not reset on respawn, but normal play never hits it.
- In Studio, after 60s of play with some rejected hits, one `[Telemetry] ...` summary line is printed.
- Join, then leave while still loading (or kick yourself right after join): no errors from `PlayerService` components, and the session is cleaned up.

Client composition:

- Start with an empty `ReplicatedStorage.ui` folder: one warning per missing template, no errors, and gameplay (movement, attacks, parkour) still works.
- With templates present: the Katana button is hidden until the server reports it in a slot; the hitmarker and weapon menu keep working after respawn.
- PC hotkeys 1-9 select slots 1-9 (only slots with an item change anything); pressing the selected slot again goes back to Fists.
- Weapon swap A -> B -> A: animations play immediately on the second equip (cached tracks), and no stale `Ended` cuts a replayed attack short.

Parkour:

- Hang on a `Climbable` ledge, traverse left/right, turn outer and inner corners, mantle with Forward, lower with Backward, and let go by releasing Space.
- At a blocked ledge end, hold the direction for a few seconds: no hitching, and the corner probe re-checks at most every 0.2s.
- Vault a low wall, and top-hop onto a raised platform followed immediately by a normal jump: the jump works right after the hop (native jump is restored when the launch's Jumping state ends).
- An unanchored or moving `Climbable` part can still be grabbed after it moves.
- Attacks (tap and hold) do nothing while hanging, mantling or vaulting; they work again right after landing.
- Sprint is blocked while hanging, mantling or vaulting, and resumes afterwards without re-pressing Sprint (Fists and Katana allow sprinting while attacking, so attacks never block it with current content).
