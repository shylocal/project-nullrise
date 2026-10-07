# project-nullrise

Roblox Luau game (R6 parkour + melee combat), synced with Rojo 7.7 (`default.project.json`). Read `docs/ARCHITECTURE.md` before changing a system; when it and the code disagree, the code wins and the doc gets fixed.

## Workflow

- Work directly on `main`; commit and push without asking. No branches or PRs.
- After pulling, run `~/.rokit/bin/wally install` (Trove and TestEZ come from Wally; `Packages/` and `DevPackages/` are not in git).
- The gate is `sh scripts/analyze.sh` (luau-lsp with Roblox types + selene). It must report zero diagnostics before every commit. New files must sit in a Rojo-mapped folder (`src/server`, `src/client`, `src/shared`, `src/packages`, `tests`) to resolve.
- TestEZ specs in `tests/specs` run only in Studio (`require(game:GetService("TestService").RunTests).Run()`), so ask the user to run them and paste results. Manual smoke tests are in `docs/TESTING.md`.
- Never commit `sourcemap.json`, `scripts/globalTypes.d.luau` or `roblox.yml` (all generated).

## Code style

- Every non-vendored module is `--!strict`. Tabs; snake_case locals and module-private functions; PascalCase public methods, fields and module tables.
- Trove for cleanup, Signal for events, constructors take a typed deps table checked with `Deps.check`.
- Config lives in `src/shared/config` and is validated at load; no silent fallbacks like `x or 0.15`.
- Weapon numbers (damage, timing, range, cooldowns) and movement speeds are gameplay feel: change them only on purpose, and update `tests/specs/WeaponGolden.spec.lua`.

## TestEZ pitfalls the analyzer cannot catch

- `expect`, `describe` and `it` exist only inside the spec's returned function. Helpers that call `expect` must be declared inside `return function() ... end`, not at module level.
- `FakePlayers:Add` fires `PlayerAdded` synchronously, so a whole join (including store hooks) runs before `Add` returns. Inside those hooks, look the player up with `GetPlayers()` instead of a local `Add` has not assigned yet.
- Never `WaitForChild` without a timeout in specs.

## Combat gotchas

- The server's copy of a weapon does not follow client-side swing animations, so never validate hits against the server's hitpoint position. Use reach from the attacker, on-body distance, facing and line of sight (`CombatValidation.lua`).
- After changing an animation, re-bake `src/shared/weapons/AnimationManifest.lua` with `tests/tools/BakeAnimationManifest` (steps in `docs/DEPENDENCIES.md`); move timings must fit the baked markers or the Catalog refuses to load.
- `Combat.LogRejectsInStudio` prints every rejected hit as `[CombatDebug]` with its measurements in Studio; use it to diagnose hits that do not register.
