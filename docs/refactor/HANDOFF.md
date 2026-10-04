# Refactor handoff (read this first when resuming)

Last updated: 2026-10-05. Work happens directly on `main` (commit + push without asking; no branches/PRs).

## Where things stand

| Step | Status |
|---|---|
| Bug-fix sweep (combat LOS, always-reply, movement window, inventory, UI, gamepad, top-hop jump) | Done, on main, tested in Studio: 151/151 specs passed |
| Tooling: `scripts/analyze.sh` (luau-lsp + selene), aftman tools | Done |
| Design contract `docs/REFACTOR_PLAN.md` | Done (§16 deviation log, §17 Phase 1 status, §18 Phase 2 status, §19 Phase 3 status) |
| Phase 1 – foundations (server Runtime/sessions/RemoteBudget/Telemetry, shared config/Catalog/Schema/CharacterQuery, parkour state machine/ClimbableIndex/CharacterState arbiter, client session owners/TrackCache) | Done, pushed (7212c96..b084791) |
| Phase 2 – features (data-driven moves, DamageService, lag compensation, CombatFx, items + ProfileStore persistence, asset contracts, animation manifest tool, selene, Wally) | Done, pushed (839c7b3..7466199) |
| Phase 3 – `--!strict` everywhere + naming + dead code + early-HitStart hit buffer | Done, pushed |
| Integrate 3 (analyzer zero, rojo build, commit, push) | Done, pushed (see plan §19) |
| Adversarial review (server+shared lens, client lens) | Done (ecdd430): 10 findings, none critical or high, in `docs/refactor/REVIEW_FINDINGS.md` |
| Fix review findings | **IN PROGRESS when the last session ended (2026-10-05).** Two agents ran in parallel: FIX-SERVER (findings 1–7: src/server, src/shared, server specs) and FIX-CLIENT (findings 8–10: src/client, client specs). Each was told to mark findings Fixed/Rejected/Deferred in REVIEW_FINDINGS.md, add §14 notes to the plan, and commit and push. See "Resuming the fixes" below |
| Finish (docs/ARCHITECTURE.md from the plan, update README/DEPENDENCIES/TESTING/VENDORED/THREAT_MODEL/review docs) | Not started |

### Resuming the fixes

1. Run `git log --oneline -10` and `git status`. Commits after fb2953d are fix commits. Uncommitted changes are partial fix work: finish it, or revert it with `git checkout -- <paths>`.
2. Open `docs/refactor/REVIEW_FINDINGS.md`. Every finding that isn't marked Fixed, Rejected or Deferred is still open. Fix it with a regression spec, following the suggested fix written there.
3. Gate: `~/.rokit/bin/wally install`, then `sh scripts/analyze.sh` must report zero luau-lsp and selene diagnostics, then `~/.aftman/bin/rojo build default.project.json -o <tmp>.rbxlx` must succeed.
4. Then do **Finish**:
   - Turn `docs/REFACTOR_PLAN.md` into `docs/ARCHITECTURE.md`, keeping a short history section.
   - Update README, DEPENDENCIES, TESTING, VENDORED and THREAT_MODEL, and mark the items done in CODEBASE_REVIEW and ARCHITECTURE_REVIEW.
   - Mark this table complete, then commit and push to main.

Nothing after Phase 2 has been run in Studio yet. The pre-refactor baseline was 151/151.

## Phase 3 (done)

Three agents (S-server, S-parkour, S-client) made every module under `src/**` and `tests/**` `--!strict` (vendored code excepted), and S-server fixed the confirmed early-HitStart bug: Hits that arrive while a HitStart is armed are now buffered and validated when the window opens (`CombatService._buffer_hit` / `_activate_pending`, specs in `CombatHitBuffer.spec.lua`). S-parkour also fixed a per-frame error on A/D while hanging on a non-`Part` guide (plan §14.13). INTEGRATE-3 reconciled the cross-agent items, spot-checked the risky files for behaviour changes, and committed and pushed. Deviations are in plan §16 (Phase 3 block), and status is in §19.

## How to resume (agent procedure)

Every implementer and integrator reads `docs/refactor/AGENT_BRIEF.md` first: rules, the analyzer gate, house style, and who may commit.
1. ~~Integrate 3~~ (done).
2. **Adversarial review (next):** two read-only agents. Compare against the pre-refactor commit `ee75e22` (`git diff ee75e22..HEAD`).
   - Server + shared lens: exploits (malformed, NaN or spammed remotes, move-id replay, hits through walls, inventory dupes and session-lock races, DataStore failure, BindToClose), lifecycle leaks, lag-comp abuse, join races, and Studio without API access.
   - Client lens: respawn/teardown leaks, action-arbiter leases never released, HumanoidOverrides restore order, parkour regressions, stale TrackCache tracks, input pass/sink, missing UI templates, per-frame cost.
3. **Finish:** one agent. It verifies and fixes the confirmed bugs (with regression specs) and turns `docs/REFACTOR_PLAN.md` into `docs/ARCHITECTURE.md` (keep a short history). It also updates README, DEPENDENCIES, TESTING, VENDORED, THREAT_MODEL, and the review docs. Then analyzer zero, rojo build, commit, push.

The ranked review behind all of this is in `docs/refactor/REVIEW_IDEAS.md`.

## User decisions to implement (2026-10-05, after the review fixes land)

1. **Attacks and ledge grabs (confirmed by the user).** The player CAN grab a ledge while light-attacking or charging. **The grab cancels that attack.**
   - In `src/client/controllers/CharacterState/Policy.lua`, attack activities (`Attack`, `AttackRooted`, the charge activity) must NOT block `Grab`. Hang already blocks Attack and Charge.
   - On a successful grab, cancel the current attack, whether a light attack or a Heavy charge:
     - release its lease;
     - stop its animation;
     - stop and drop the hitbox;
     - clear any pending or buffered move;
     - send HitStop for the active move (or abandon it cleanly), so the server clears it.
   - A good hook: CharacterState fires `Changed` when the Hang lease starts. CombatController reacts by running `clear_attack_lifecycle` and `release_lease`, the same path as Reset or a cancelled charge.
   - Specs:
     - grabbing during a light attack succeeds and ends the attack;
     - grabbing during a charge succeeds and ends the charge;
     - no lease is left held, and you can attack again after releasing the ledge (the Hang lease still blocks attacks while hanging).
2. **Light-attack cooldowns.**
   - Fists: 0.3 → **0.35s**. Katana: 0.35 → **0.6s**.
   - Change `Cooldown` in `src/shared/weapons/Fists.lua` and `Katana.lua` (move defaults or Light1/Light2).
   - Raise the server `MinDuration` to match, so the server enforces the same pace: the Validator requires `Cooldown >= MinDuration`.
   - Leave HitStartAt, HitWindow and Damage unchanged.
   - Update `tests/specs/WeaponGolden.spec.lua`, and record the change in the plan §14 and the README.

## Open decisions for the user

- (Resolved 2026-10-05; see "User decisions to implement".)


## User to-dos in Studio

- Run `~/.rokit/bin/wally install` after pulling, before `rojo serve`. Packages come from Wally and are not in git.
- Set Avatar Type to R6 (Game Settings > Avatar).
- Turn on "Enable Studio Access to API Services" to exercise real persistence. Otherwise ProfileStore's mock is used and nothing is saved.
- Bake the animation markers:
  1. Run `require(game.TestService.tools.BakeAnimationManifest).Run()` in the command bar, in Edit mode.
  2. Copy `ServerStorage.AnimationManifest_Generated` over `src/shared/weapons/AnimationManifest.lua`.
  3. Commit.
- The Katana template needs `Handle` and `Mesh` BaseParts. `Mesh` must be welded or jointed to `Handle` and have a `Hitpoint` attachment; otherwise the Studio boot stops with a named error, which is intended.
- Run the TestEZ suite with `require(game:GetService("TestService").RunTests).Run()`, then the smoke tests in `docs/TESTING.md`.

## Riskiest areas to test

1. Parkour parity after the state-machine rewrite:
   - overrides restore after hang, mantle, vault and top-hop;
   - the jump latch after a completed vault or mantle with Space held;
   - corners and lower-ledge;
   - jumping right after a top-hop;
   - moving Climbables.
2. Combat:
   - Heavy hold/release gets a reply;
   - early-HitStart hits land (after the fix);
   - hits on a target's weapon land on the body;
   - shared Attack budget (12/s, burst 3) with fast tap→hold mixes.
3. Persistence: the Katana persists across rejoin, and a second server stealing the session kicks the first.
4. Trove 1.8 (Wally): cleanup errors no longer propagate.
