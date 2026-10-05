# Refactor handoff

Last updated: 2026-10-05. Work happens directly on `main` (commit and push without asking; no branches or PRs).

**The refactor is complete in code and docs.** The architecture as built is in [docs/ARCHITECTURE.md](../ARCHITECTURE.md). The original design contract is in git history: `git show 973df88:docs/REFACTOR_PLAN.md`.

## Verified in Studio (2026-10-05)

- Every P1 smoke test in docs/TESTING.md passed.
- First post-refactor TestEZ run: 555/574. The 19 failures were fixed in 687d70b (overkill was counted as applied damage) and 32987e9 (spec bugs).
- Re-run: **574 passed, 0 failed**. The refactor is complete.
- The animation manifest was baked on 2026-10-05. To pass it, Katana Light1 needed its own `HitWindow = 0.6`, because its HitStop marker is at 0.667s.

## Status

| Step | Status |
|---|---|
| Bug-fix sweep (combat LOS, always-reply, movement window, inventory, UI, gamepad, top-hop jump) | Done; tested in Studio before the refactor: 151/151 specs passed |
| Tooling: `scripts/analyze.sh` (luau-lsp + selene), aftman tools | Done |
| Design contract (`docs/REFACTOR_PLAN.md`) | Done, then replaced by `docs/ARCHITECTURE.md` |
| Phase 1: foundations | Done (7212c96..b084791) |
| Phase 2: features | Done (839c7b3..7466199) |
| Phase 3: `--!strict`, naming, dead code, early-HitStart hit buffer | Done |
| Integrate 3 (analyzer zero, rojo build) | Done |
| Adversarial review (server+shared lens, client lens) | Done (ecdd430): 10 findings, none critical or high |
| Fix review findings | Done: all 10 fixed, see `REVIEW_FINDINGS.md` (ARCHITECTURE.md §14.15–§14.20) |
| User decision 1: a ledge grab cancels an in-flight attack | Done (ARCHITECTURE.md §14.21) |
| User decision 2: light-attack cooldowns Fists 0.35s, Katana 0.6s | Done, 973df88 (ARCHITECTURE.md §14.22) |
| Finish: `docs/ARCHITECTURE.md`; README, DEPENDENCIES, TESTING, VENDORED and THREAT_MODEL updated; CODEBASE_REVIEW and ARCHITECTURE_REVIEW items marked done | Done |
| Final gate: `sh scripts/analyze.sh` zero findings; `rojo build` succeeds | Done |

## What remains (the user, in Studio)

Nothing after the pre-refactor bug-fix sweep has been run in Studio. Three things remain:

1. **Run the whole TestEZ suite.** The pre-refactor baseline was 151/151; every spec has since been rewritten or added and checked only by inspection and the analyzer. Run `require(game:GetService("TestService").RunTests).Run()` in a Server-context command bar during Play.
2. **Run the smoke tests** in [docs/TESTING.md](../TESTING.md#smoke-tests), P1 items first.
3. **Bake the animation manifest:**
   1. Run `require(game.TestService.tools.BakeAnimationManifest).Run()` in the command bar, in Edit mode.
   2. Copy `ServerStorage.AnimationManifest_Generated` over `src/shared/weapons/AnimationManifest.lua`.
   3. Commit it.

   This is the first time move timing is checked against the real animations. In particular, the Katana light `MinDuration` of 0.6s must fit within those animations' lengths.

Setup before any of that:

- Run `~/.rokit/bin/wally install` after pulling, before `rojo serve`. Packages come from Wally and are not in git.
- Set Avatar Type to R6 (Game Settings > Avatar).
- Turn on "Enable Studio Access to API Services" and set `Config.Data.UseMockInStudio = false` to exercise real persistence. Otherwise ProfileStore's mock is used and nothing is saved.
- The Katana template needs `Handle` and `Mesh` BaseParts. `Mesh` must be welded or jointed to `Handle` and have a `Hitpoint` attachment; otherwise the Studio boot stops with a named error, which is intended.

## Riskiest areas to test

1. **Parkour parity after the state-machine rewrite:**
   - overrides restore after hang, mantle, vault and top-hop;
   - the jump latch after a completed vault or mantle with Space held;
   - corners and lower-ledge;
   - jumping right after a top-hop;
   - moving Climbables.
2. **Combat:**
   - the new light cooldowns feel right;
   - Heavy hold and release gets a reply;
   - early-HitStart hits land;
   - hits on a target's weapon land on the body;
   - a ledge grab cancels the attack cleanly;
   - the shared Attack budget (12/s, burst 3) holds up with fast tap/hold mixes.
3. **Persistence:** the Katana persists across rejoin, and a second server stealing the session kicks the first.
4. **Trove 1.8 (Wally):** cleanup errors no longer propagate.

## Resuming work

Every agent reads `docs/refactor/AGENT_BRIEF.md` first: rules, the analyzer gate, house style and who may commit. When Studio results come back, fix failures with regression specs, and record any new intentional behaviour change in ARCHITECTURE.md (History, next §14 number). The ranked review behind the refactor is in `docs/refactor/REVIEW_IDEAS.md`.
