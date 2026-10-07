# Testing

The automated suite uses TestEZ and runs only in Roblox Studio. The game never runs tests at startup.

## Static checks (no Studio needed)

From the repository root:

```sh
aftman install
~/.rokit/bin/wally install
sh scripts/analyze.sh
rojo build default.project.json -o build/project.rbxlx
```

- `wally install` fetches Trove and TestEZ into the git-ignored `Packages/` and `DevPackages/`. Rojo fails on a fresh clone until it has run. `analyze.sh` runs it automatically when either folder is missing.
- `sh scripts/analyze.sh` is the gate. It type-checks `src` and `tests` with luau-lsp (Roblox types plus a Rojo sourcemap it regenerates), then lints them with selene (`selene.toml`). It must report zero luau-lsp diagnostics and zero selene errors or warnings.
- `rojo build` validates the project structure only. It does not type-check Luau, run physics or exercise networking.

There is no CI workflow; run these checks locally.

## Studio TestEZ run

TestEZ 0.4.1 is a Wally dev dependency ([VENDORED.md](VENDORED.md)). Rojo maps `DevPackages/TestEZ.lua` to `TestService.TestEZ`, next to `RunTests` and `specs`. Then:

1. Run `rojo serve`.
2. In Studio, connect the Rojo plugin and start a local Play session.
3. In a Server-context command bar, run:

   ```lua
   require(game:GetService("TestService").RunTests).Run()
   ```

`tests/RunTests.lua` refuses to run outside Studio.

**Status:** last full Studio run, 2026-10-05: 581 passed, 0 failed.

Before running, set up Studio:

- Set Avatar Type to R6 (Game Settings > Avatar).
- Make sure the Katana template in `ServerStorage.weapon_models` has a `Handle`, and a `Mesh` that is welded or jointed to it and has a `Hitpoint` attachment. Otherwise the boot stops with a named `AssetContracts` error, which is intended.
- To exercise real persistence, turn on "Enable Studio Access to API Services" and set `Config.Data.UseMockInStudio = false`. Set it back afterwards.

## Coverage boundary

The specs cover:

- config, Envelope and the Schema/Freeze utilities;
- the weapon Catalog, Validator and golden values, ItemCatalog and the animation and asset contracts;
- Runtime, PlayerService and PlayerSession lifecycle;
- RemoteBudget, InboundSink and Telemetry;
- combat: request handling, move timing, the hit buffer, validation, lag compensation, damage and FX;
- PlayerDataService over a fake ProfileStore, the profile Schema, inventory and weapon services;
- client session clients, input, CharacterState and HumanoidOverrides;
- the combat controller lifecycle (on a fake clock and fake animation tracks), track caching;
- parkour state, queries, ledge detection, traversal budget, vault and top-hop, and ClimbableIndex.

The suite does not prove real map traversal, that the animation assets and their markers exist, replicated physics, real DataStore behaviour, published-server networking, or resistance to an adversarial client.

## Combat cases that must stay regression-tested

- A `Hit` without a tagged hitpoint `Attachment` or a finite impact `Vector3` is rejected.
- A valid hit must pass the target, range, facing, hitpoint, impact-on-body and line-of-sight checks. A wall between attacker and target blocks the hit even when the hitpoint-to-impact segment is clear.
- Every well-formed `Attack` that passes the remote budget gets exactly one `AttackAccepted` or `AttackRejected`. Malformed or budget-dropped requests get at most one `AttackRejected` per `RejectReplyInterval`.
- A new move before the previous move's `MinDuration` is rejected.
- An early `HitStart` is armed and opens the hit window at `HitStartAt`. Hits that arrive while it is armed are buffered and validated when the window opens.
- A Heavy held up to `Hold.MaxHoldTime` still deals damage after release. A second Heavy cannot land within `HoldTime + HitStartAt` of a released one.
- A hit that fails reach or body checks now but passes against the rewound position is accepted and counted as `Rewound`.
- Damage goes only through `DamageService`. A blocked or ineffective hit (policy, ForceField) sends no `HitConfirmed`.
- A weapon change resets the combo sequence but not the cooldown or remote budget state.
- Player removal clears every player-scoped combat state.
- A target that failed validation `MaxRejectsPerTarget` times is ignored for the rest of the move.
- Several targets can be hit in one window, on the same frame too, within the per-target dedupe and per-move caps.
- The hitmarker shows only after the server confirms damage.

## Smoke tests

This list covers the behaviour the specs cannot reach. Run it after the TestEZ suite, with Fists and then with Katana where it applies. **P1** items are the riskiest and come first. Use two players (Test > Clients and Servers) where noted.

### Boot and content

- **P1** The server boots without `failed to start AssetContracts`. If it stops there, the error lists each template problem (for example a Katana `Mesh` not welded to `Handle`). Fix the template in `ServerStorage.weapon_models`.
- Studio Play prints `[PlayerData] Studio is using the ProfileStore mock; data is not saved`, and the Katana is in slot 2 on first join.
- Put a `GuiButton` with `WeaponId = "Nope"` in the WeaponMenu template: the Studio client stops at boot with a `[UiContracts]` error. Remove it again.
- Start with an empty `ReplicatedStorage.ui` folder: one warning per missing template (none for `DamageIndicator`), no errors. Movement, attacks, parkour and the hit highlight still work.
- After baking the animation manifest ([DEPENDENCIES.md](DEPENDENCIES.md#animation-manifest)), the suite and the boot still pass. If the Catalog then fails to load, it names the move whose timing does not fit its animation, for example a Katana light whose 0.6s `MinDuration` is longer than the animation.
- An R15 character: the client warns and skips character setup, and the server refuses to arm it.

### Combat

- **P1** Light combo with each weapon: tap repeatedly and see Light1 and Light2 alternate (Fists: right fist, then left). Fists repeats at most every 0.35s and Katana every 0.6s. Mashing faster never gets a swing rejected, and no swing plays without its hit landing.
- **P1** Heavy: hold Primary past 0.15s, see the windup pause on its HitStart marker, release, and hit. The Heavy gets a reply, and a combo tap right after it still works. Hold for 10s: the charge releases by itself and still hits.
- **P1** Early HitStart and the hit buffer: set Network > Incoming Replication Lag to about 0.2s and stand right next to a dummy. Combo taps and Heavy releases land on the first frame of contact, and each target is damaged once per swing. In the Telemetry summary `Combat/EarlyHitStart` counts but `Combat/NotActive` does not rise. A HitStop or respawn before the window opens drops the buffered hits.
- **P1** Hit an enemy who holds a Katana so that your swing passes through the blade first: the hit lands on the body.
- **P1** Hits near the end of your reach and while sprinting at a target land and confirm. With `Combat.LogRejectsInStudio` on, every rejected hit prints a `[CombatDebug]` line with its reason and measured distances.
- Rewound hit: with replication lag, hit a moving target near the end of your reach. The hit lands, `Combat/Rewound` counts, and suspicion does not rise.
- Attack through a wall, and with missing hit arguments: no damage.
- Two valid targets in consecutive frames (and on the same frame): both take damage.
- Damage policies: a target with the `Invulnerable` attribute takes no damage and gives no hitmarker. Untagged Humanoid dummies still take damage. A target with a ForceField takes no damage and gives no hitmarker.
- FX: the victim flashes a white highlight for every nearby player. The victim sees its damage flash if the `DamageIndicator` template (with a `Flash` GuiObject) exists.
- Budget: spam `Attack` with a bad move id (or past the budget) from a client. The client receives at most one `AttackRejected` per 0.25s and the server stays responsive. Respawn repeatedly while attacking: normal play never hits the budget. Fast tap/hold mixes share the `Combat.Attack` budget (12/s, burst 3) without stuck attacks.
- Respawn or die mid-swing, then attack again: combo, Heavy, hitmarker, highlight and weapon menu all work, and the equipped weapon is kept.
- Replace the Animator mid-swing: the attack ends at once and the next attack works.
- In Studio, after 60s of play with some rejected hits, one `[Telemetry] ...` summary line prints, with no client-chosen action names.

### Parkour

- **P1** Overrides restore: after hang, mantle, vault and top-hop, AutoRotate, jump and walk speed are back to normal.
- **P1** Jump latch: complete a vault or mantle while holding Space. No jump fires until Space is released and pressed again.
- **P1** Ledge grab during an attack:
  - Tap a light attack and jump to grab mid-swing. The grab succeeds, the swing stops, no hit lands after the grab, and taps and holds do nothing while hanging.
  - Hold Primary until the Heavy pauses, then grab while holding. The charge ends, and releasing Primary while hanging starts no hit.
  - Drop off or mantle, then tap: the next light attack plays at once (no stuck lease), and sprint works.
- Hang on a `Climbable` ledge, traverse left and right, turn outer and inner corners, mantle with Forward, lower with Backward, and let go by releasing Space.
- At a blocked ledge end, hold the direction for a few seconds: no hitching (the corner probe re-checks at most every 0.2s).
- Vault a low wall, and top-hop onto a raised platform followed immediately by a normal jump: the jump works right after the hop.
- Moving Climbables: a tagged Model moved by PivotTo or a tween, a Model with no PrimaryPart whose parts are moved directly, and an unanchored part can all be grabbed after they move.
- MeshPart, WedgePart and Union guides: hang on each and hold A, then D. The character shimmies or stops at the edge with no output errors. A cylinder `Part` guide still traverses.
- Attacks do nothing while hanging, mantling or vaulting and work again right after landing.
- Sprint is blocked while hanging, mantling or vaulting and resumes afterwards without pressing Sprint again. Holding Sprint while standing still neither sprints nor vaults.
- Alt-tab out while holding Left Shift, come back, press Left Shift once: you sprint.
- A climbable surface needs the `Climbable` tag; the `Climbable` collision group alone is ignored.
- Sprint, vault and top-hop at full speed, and take a long fall: no `MovementValidation` warning.

### Inventory and persistence

- **P1** The Katana persists across rejoin: with API access and the mock off (or on a live server), select or move items, leave, rejoin, and see the same inventory.
- **P1** Session steal (two servers): join the same account on a second live server while the first session is open. The first server kicks that player with "Your data was opened on another server."
- Live load failure: on a live server with the DataStore unavailable, the player is kicked with the load-failed message. In Studio the same failure only warns and plays on an in-memory profile.
- Equip by hotkey: press 2 for the Katana, press 2 again for Fists. PC hotkeys 1–9 select slots 1–9; only slots with an item change anything.
- Equip by WeaponMenu: the Katana button equips it, the Fists button goes back to Fists. The Katana button is hidden until the server reports Katana in a slot.
- Rapid 1/2/1/2: the weapon settles on the last pick about 0.2s later, without flicker, errors or a stuck combat state. Swap during an attack and during its cooldown: the cooldown is kept.
- Weapon swap A → B → A: animations play at once on the second equip, and no stale `Ended` cuts a replayed attack short.
- Leave the game, and leave while still loading: no component errors on the server. On a live server the profile is released, so an immediate rejoin does not wait on a session lock.
- Respawn: the weapon menu and hitmarker keep working.

### Input

- Touch controls for Jump, Forward, Backward, Left and Right.
- Gamepad primary, jump, sprint and parkour direction controls.

### Multiplayer movement observer

Follow the steps in [THREAT_MODEL.md](THREAT_MODEL.md#multiplayer-validation-plan).
