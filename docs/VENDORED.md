# Third-party packages

Third-party Luau code reaches the game in two ways: **Wally** packages, which are pinned in `wally.toml` / `wally.lock` and installed into `Packages/` and `DevPackages/` (both git-ignored), and **vendored** copies, which are committed under `src/`. Require paths are the same for both: `default.project.json` maps each package by name under `ReplicatedStorage.packages` or `TestService`.

## Wally packages

| Package | Wally name | Realm | Installed to | Mapped to | License |
| --- | --- | --- | --- | --- | --- |
| Trove | `sleitnick/trove@1.8.0` | `[dependencies]` | `Packages/Trove.lua` (+ `Packages/_Index`) | `ReplicatedStorage.packages.Trove` | MIT (declared in the package's `wally.toml`; RbxUtil carries the license text) |
| TestEZ | `roblox/testez@0.4.1` | `[dev-dependencies]` | `DevPackages/TestEZ.lua` (+ `DevPackages/_Index`) | `TestService.TestEZ` | Apache-2.0 (`LICENSE` ships in the package) |

- **Manifest:** `wally.toml` declares the project as the private package `shylocal/project-nullrise` (realm `shared`); `wally.lock` is committed.
- **Install:** `~/.rokit/bin/wally install` (Wally is pinned in `aftman.toml`, which Rokit also reads). `sh scripts/analyze.sh` runs it automatically when `Packages/` or `DevPackages/` is missing. Run it before `rojo serve` / `rojo build` on a fresh clone, or Rojo fails on the missing `Packages/` paths.
- **TestEZ stays out of the shipped tree.** It is a dev dependency mapped only under `TestService`; nothing from `DevPackages/` is mapped into `ReplicatedStorage`. `RuntimeContracts.spec` asserts that `ReplicatedStorage.packages` has no `TestEZ`.
- **TestEZ 0.4.1 is identical** (apart from whitespace) to the copy that used to live in `tests/TestEZ/`, so `tests/RunTests.lua` and the specs are unchanged.
- **Trove 1.8.0 differences from the old 2021 copy** (checked against every caller):
  - Cleanup functions are run with `task.spawn` and threads are cancelled with `task.cancel`. An error inside a cleanup function no longer aborts the rest of `Clean`.
  - `Connect` requires a signal-like object with both `Connect` and `Once`. `RBXScriptSignal`s and `packages.Signal` qualify; no code or spec passes a hand-built signal.
  - Tables may also be cleaned through lowercase `destroy` / `disconnect`.
  - `AttachToInstance` errors for an instance outside the DataModel. Nothing calls it: `PlayerSession` and `CharacterController` follow `Destroying` instead.
  - `Remove` still cleans the removed object, as the old copy did.
- The Trove package also contains its own `init.test.luau` (written for a different test runner). It is never required; it maps as an inert child ModuleScript of `Trove`.

## Vendored packages

| Package | Path | Mapped to | Upstream | Version | License |
| --- | --- | --- | --- | --- | --- |
| Signal | `src/packages/Signal.lua` | `ReplicatedStorage.packages.Signal` | GoodSignal by stravant | Not recorded (2021 file) | MIT; the original header notice is restored in the file |
| ShapecastHitbox | `src/packages/ShapecastHitbox/` | `ReplicatedStorage.packages.ShapecastHitbox` | ShapecastHitbox by Phin (TeamSwordphin) | Not recorded. Header: "August 2024". | Not vendored; check upstream |
| ProfileStore | `src/server/vendor/ProfileStore.lua` | `ServerScriptService.server.vendor.ProfileStore` (server only, never replicated) | MadStudioRoblox/ProfileStore | v1.0.3, commit `45c9847` | **Apache-2.0**; the license is at `licenses/ProfileStore.LICENSE` |

Why these stay vendored:

- **Signal:** Wally's `stravant/goodsignal` has no `Destroy` on signals or connections, so `Trove:Add(signal)` would fail; `sleitnick/signal` changes the API surface. The local copy adds `Connection.Destroy` and `Signal.Destroy` aliases (noted in its header).
- **ShapecastHitbox:** it carries one local change, `Settings.lua` sets `Debug_Visible = false` (upstream defaults to `true`, which draws debug geometry for every cast on every client). The API of the Wally release (0.2.9) is unverified against our usage. Keep the `Debug_Visible` change through any upgrade.
- **ProfileStore:** it is server-only, so it lives under `src/server/vendor/` rather than in the replicated packages. It could later move to Wally as `lm-loleris/profilestore@1.0.3` under `[server-dependencies]`, mapped under `ServerScriptService`.

`src/packages/**`, `src/server/vendor/**`, `Packages/**` and `DevPackages/**` are excluded from luau-lsp and selene (`scripts/analyze.sh`, `selene.toml`).

## Upgrading

- **Wally package:** change the version in `wally.toml`, run `wally install`, commit `wally.lock`, then run `sh scripts/analyze.sh` and the Studio TestEZ suite (`docs/TESTING.md`).
- **Vendored package:** replace the files, keep the license notice and the local changes listed above, update this table, then run the same checks. An upgrade is its own change.
