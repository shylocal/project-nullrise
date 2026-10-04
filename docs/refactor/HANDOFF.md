# Refactor handoff (read this first when resuming)

Last updated: 2026-10-04. Work happens directly on `main` (commit + push without asking; no branches/PRs).

## Where things stand

| Step | Status |
|---|---|
| Bug-fix sweep (combat LOS, always-reply, movement window, inventory, UI, gamepad, top-hop jump) | Done, on main, tested in Studio: 151/151 specs passed |
| Tooling: `scripts/analyze.sh` (luau-lsp + selene), aftman tools | Done |
| Design contract `docs/REFACTOR_PLAN.md` | Done (§16 deviation log, §17 Phase 1 status, §18 Phase 2 status) |
| Phase 1 – foundations (server Runtime/sessions/RemoteBudget/Telemetry, shared config/Catalog/Schema/CharacterQuery, parkour state machine/ClimbableIndex/CharacterState arbiter, client session owners/TrackCache) | Done, pushed (7212c96..b084791) |
| Phase 2 – features (data-driven moves, DamageService, lag compensation, CombatFx, items + ProfileStore persistence, asset contracts, animation manifest tool, selene, Wally) | Done, pushed (839c7b3..7466199) |
| Phase 3 – `--!strict` everywhere + naming + dead code | **In progress / possibly partial and UNCOMMITTED** (see below) |
| Integrate 3 (analyzer zero, rojo build, commit, push) | Not started |
| Adversarial review (server+shared lens, client lens) | Not started |
| Finish (fix confirmed bugs, docs/ARCHITECTURE.md from the plan, update docs, commit, push) | Not started |

Nothing after Phase 2 has been run in Studio yet. The pre-refactor baseline was 151/151.

## Phase 3 in flight when this note was written

Three agents were editing the working tree concurrently (ownership per `REFACTOR_PLAN.md` §11 Phase 3):
- **S-server**: `src/server/**` (not vendor) + `src/shared/**`. It was also told to fix a **confirmed bug**: Hit packets that arrive while an early HitStart is armed (`PendingHitStart`, before `HitStartOpensAt`) are dropped as `NotActive`. The client reports each target once per swing, so that target can't land for the rest of the swing. Fix: buffer those Hit requests per active move (cap `MaxHitRequestsPerAttack`, dedupe by target), validate them in order when the window opens, and drop the buffer on clear or attacker change. Add specs.
- **S-parkour**: ParkourController/**, MovementController, CharacterState/**. Typing only, no logic changes.
- **S-client**: the rest of `src/client/**` + `tests/**`. This includes removing the v1 weapon-shape branch in `tests/specs/WeaponService.spec.lua`.

**If resuming:** run `git status` / `git diff`. Anything uncommitted is partial Phase 3 work. Either finish it (each area must end with zero diagnostics from `sh scripts/analyze.sh`) or revert that area with `git checkout -- <paths>` and redo it. Check that the early-HitStart buffering fix actually landed in `src/server/services/CombatService.lua`.

## How to resume (agent procedure)

Every implementer and integrator reads `docs/refactor/AGENT_BRIEF.md` first: rules, the analyzer gate, house style, and who may commit.
1. **Integrate 3:** one agent. It resolves cross-agent issues, gets `sh scripts/analyze.sh` to zero (luau-lsp + selene), runs `~/.rokit/bin/wally install` then `~/.aftman/bin/rojo build default.project.json -o <tmp>.rbxlx`, appends deviations to plan §16, adds a "Phase 3 status" section, commits on main and pushes.
2. **Adversarial review:** two read-only agents. Compare against the pre-refactor commit `ee75e22` (`git diff ee75e22..HEAD`).
   - Server + shared lens: exploits (malformed, NaN or spammed remotes, move-id replay, hits through walls, inventory dupes and session-lock races, DataStore failure, BindToClose), lifecycle leaks, lag-comp abuse, join races, and Studio without API access.
   - Client lens: respawn/teardown leaks, action-arbiter leases never released, HumanoidOverrides restore order, parkour regressions, stale TrackCache tracks, input pass/sink, missing UI templates, per-frame cost.
3. **Finish:** one agent. It verifies and fixes the confirmed bugs (with regression specs) and turns `docs/REFACTOR_PLAN.md` into `docs/ARCHITECTURE.md` (keep a short history). It also updates README, DEPENDENCIES, TESTING, VENDORED, THREAT_MODEL, and the review docs. Then analyzer zero, rojo build, commit, push.

The ranked review behind all of this is in `docs/refactor/REVIEW_IDEAS.md`.

## Open decisions for the user

- **Should an attack in progress block grabbing a ledge?** Today you cannot attack while hanging or vaulting, but you can grab mid-swing. It's a one-line change in `src/client/controllers/CharacterState/Policy.lua`.
- **Light-attack cooldown:** it went from 0.1 to 0.3s (Fists) / 0.35s (Katana) so the server-enforced MinDuration is meaningful. Retune it if it feels slow.

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
