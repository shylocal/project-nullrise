# Testing

The automated suite uses TestEZ and Roblox Studio. The repository does not run tests during game startup.

## Static checks

From the repository root:

```sh
aftman install
~/.rokit/bin/wally install
rojo build default.project.json -o build/project.rbxl
```

`wally install` fetches Trove and TestEZ into the git-ignored `Packages/` and `DevPackages/` folders. Rojo fails on a fresh clone until it has run (`sh scripts/analyze.sh` runs it automatically when either folder is missing). The build check validates project structure but does not parse or type-check Luau, and does not execute Roblox physics or multiplayer networking.

`sh scripts/analyze.sh` type-checks `src` and `tests` with luau-lsp (Roblox types plus a Rojo sourcemap it regenerates), then lints them with selene (`selene.toml`). It must report zero luau-lsp diagnostics and zero selene errors; fix selene warnings in the files you touch. There is no CI workflow; run these checks locally.

## Studio TestEZ run

TestEZ 0.4.1 is a Wally dev dependency (see `docs/VENDORED.md`). Rojo maps `DevPackages/TestEZ.lua` to `TestService.TestEZ`, next to `RunTests` and `specs`, so run `wally install` first. Start:

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
- A new move before the previous move's `MinDuration` is rejected, and an early `HitStart` (before `HitStartAt`) is armed and opens the hit window at `HitStartAt`, not before.
- A Charge move (Heavy) held up to its `Hold.MaxHoldTime` still deals damage after release.
- A hit that fails reach or body checks against the target's current position but passes against its rewound position (lag compensation) is accepted and counted as `Rewound`.
- Damage goes only through `DamageService`; a blocked or ineffective hit (policy, ForceField) sends no `HitConfirmed`.
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

## Refactor (Phase 2) smoke tests

These cover the Phase 2 items of `docs/REFACTOR_PLAN.md` §14 (3, 8, 9, 10, 11) and the Phase 2 risks. Run `wally install` and sync with Rojo first. Use two players (Test > Clients and Servers) where noted.

Boot and content contracts:

- The server boots without `failed to start AssetContracts`. If it stops there, the error lists each template problem (for example a Katana `Mesh` that is not welded to `Handle`); fix the template in `ServerStorage.weapon_models`.
- Put a `GuiButton` with `WeaponId = "Nope"` in the WeaponMenu template: the client stops at boot in Studio with a `[UiContracts]` error. Remove it again.
- With an empty `ReplicatedStorage.ui` folder, the client starts and gameplay works; the hit highlight still shows (it needs no template).
- After baking the animation manifest (`docs/DEPENDENCIES.md`), the TestEZ suite and the boot still pass.

Persistence and inventory:

- Studio Play prints `[PlayerData] Studio is using the ProfileStore mock; data is not saved`, and the Katana is in slot 2 on first join.
- Katana persists across rejoin: with `Config.Data.UseMockInStudio = false` and Studio API access on (or on a live server), select or move items, leave, rejoin and see the same inventory. Set `UseMockInStudio` back to `true` afterwards.
- Live kick on load failure: on a live test server where the DataStore is unavailable, the player is kicked with the load-failed message instead of playing on unsaved data. In Studio the same failure only warns and continues on an in-memory profile.
- Session steal: join the same account on a second live server while the first session is still open. The first server kicks that player with "Your data was opened on another server."
- Equip by hotkey: press 2 to equip the Katana, press 2 again to go back to Fists.
- Equip by WeaponMenu: the Katana button equips it, the Fists button goes back to Fists.
- Rapid 1/2/1/2 hotkeys: the weapon settles on the last pick about 0.2s later, without flicker, errors or a stuck combat state.

Combat moves, damage and FX:

- Light combo: tap repeatedly and see Light1 and Light2 alternate (for Fists, right fist then left fist), with the same damage, range and cooldown as before.
- Heavy: hold Primary past 0.15s, see the windup pause on its HitStart marker, release, and hit. The Heavy now gets an `AttackAccepted` / `AttackRejected` reply (§14.3), and a combo tap right after it still works.
- Early HitStart (§14.8): with Network > Incoming Replication Lag set to about 0.2s, swings still land. A swing whose HitStart arrives before `HitStartAt` is not dropped (it is counted as `Combat/EarlyHitStart` in the Telemetry summary).
- Rewound hit (§14.8): with replication lag, hit a moving target near the end of your reach. The hit lands and the Telemetry summary counts `Combat/Rewound`, with no rise in suspicion.
- Damage policies (§14.11): a target with the `Invulnerable` attribute set to true takes no damage and you get no hitmarker. Untagged Humanoid dummies still take damage.
- `HitConfirmed` and FX (§14.9): the hitmarker shows only on damage that landed; the victim flashes a white highlight for every nearby player; the victim sees its damage flash if the `DamageIndicator` template (with a `Flash` GuiObject) exists. A target with a ForceField takes no damage and shows no hitmarker.

Lifecycle:

- Respawn mid-swing, then attack again: combo, Heavy, hitmarker, highlight and weapon menu all still work, and the equipped weapon is kept.
- Leave the game (and leave while still loading): the server shows no component errors, and on a live server the profile is released (rejoining immediately does not wait on a session lock).

## Refactor (Phase 3) smoke tests

Phase 3 only adds types, with two behaviour fixes (`docs/REFACTOR_PLAN.md` §14.13 and §14.14). Run the Phase 1 and Phase 2 smoke tests as well, because every module changed.

- Early-HitStart hit (§14.14): set Network > Incoming Replication Lag to about 0.2s and stand right next to a dummy, so the weapon touches it as the swing starts. Fast combo taps and Heavy releases land on the first frame of contact, and each target is damaged once per swing. In the Telemetry summary, `Combat/EarlyHitStart` still counts, but `Combat/NotActive` does not rise during these swings. A HitStop or a respawn before the window opens drops the buffered hits (no damage).
- MeshPart/Union climb-guide A/D (§14.13): tag a MeshPart, a WedgePart and a UnionOperation as `Climbable`. Hang on each and hold A, then D. The character shimmies (or stops at the edge) with no error in the output. A cylinder `Part` guide still traverses as before.
