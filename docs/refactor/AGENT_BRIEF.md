# Agent brief (applies to every refactor agent)

Repo: D:/Roblox/projects/project-nullrise — Roblox Luau game, Rojo 7.7 (default.project.json).
Branch: main ONLY. Never create or switch branches, never open PRs.

Static checker: run `sh scripts/analyze.sh` (luau-lsp with Roblox types + Rojo sourcemap; regenerates sourcemap.json).
It is the gate: your owned files must end with ZERO diagnostics (errors or lint warnings), and you must not add
diagnostics elsewhere. Re-run it after edits. New files must be inside a Rojo-mapped folder (src/server, src/client,
src/shared, src/packages, tests) to resolve. selene is installed at ~/.aftman/bin/selene (config may not exist yet).

TestEZ specs live in tests/specs and run only in Studio (cannot be executed here). The user just ran the suite in
Studio on the pre-refactor code: 151 passed, 0 failed. Keep specs correct by inspection AND analyzer-clean; add specs
for every new module with pure logic. Never infinite-WaitForChild in specs.
TestEZ pitfalls the analyzer cannot catch (both broke specs in the first post-refactor Studio run):
- `expect` (and describe/it) exist only inside the spec's returned function. A helper declared at module
  level that calls `expect` gets nil at runtime. Declare such helpers inside `return function() ... end`.
- FakePlayers:Add fires PlayerAdded synchronously, so a whole join (including store hooks) runs before Add
  returns. Inside those hooks, look the player up with `GetPlayers()` instead of reading a local that Add
  has not assigned yet.

Rules:
- Gameplay feel must stay the same for Fists and Katana (damage, timing, ranges, cooldowns, movement speeds) unless
  docs/ARCHITECTURE.md (History, intentional behaviour changes §14.N) records the change.
- House style: tabs; snake_case locals/module-private functions; PascalCase public methods/fields and module tables;
  Trove for cleanup; Signal for events. No silent config fallbacks ("x or 0.15") — validate config instead.
- Only INTEGRATE / FINISH agents run git add/commit/push. Everyone else: no git commit/stash/reset/checkout/branch.
- When running concurrently with other agents, edit ONLY files your task assigns to you for this
  phase; put any needed outside change in your report under NEEDS_OUTSIDE.
- Commit messages (integrators only) end with a blank line then:
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  then `git push origin main` (authorised). Never commit sourcemap.json or .luau/globalTypes.d.luau.

Motivating ranked review: docs/refactor/REVIEW_IDEAS.md
Architecture (authoritative): D:/Roblox/projects/project-nullrise/docs/ARCHITECTURE.md (the refactor plan it replaced is
in git history: `git show 973df88:docs/REFACTOR_PLAN.md`). If you must deviate, say so in your report.

Implementer procedure: read ARCHITECTURE.md fully, then implement EXACTLY your task for this phase (only your owned files).
Read every file you will touch first, plus their callers (read-only). Work incrementally and run scripts/analyze.sh
repeatedly. Add/adjust specs. Finish with an adversarial self-review of your full diff (git diff -- <your files>):
assume it is wrong; trace runtime paths (respawn, player leaving mid-action, nil characters, Studio vs live), check
gameplay numbers are unchanged, then fix.

Final report (your last message, plain text): SUMMARY; FILES_CHANGED; ANALYZER_STATUS for your files;
DEVIATIONS_FROM_PLAN; NOT_DONE; NEEDS_OUTSIDE.
