# Vendored packages

Third-party Luau packages are copied into this repository rather than installed by a package manager. None of the copies carry a license file or a version manifest, so the details below come from the file headers and the code itself. Check each upstream before relying on a license or version.

| Package | Path | Mapped to | Upstream | Version | License |
| --- | --- | --- | --- | --- | --- |
| ShapecastHitbox | `src/packages/ShapecastHitbox/` | `ReplicatedStorage.packages.ShapecastHitbox` | ShapecastHitbox by Phin (TeamSwordphin) | Not recorded. Header: "August 2024". | Not vendored; check upstream |
| Signal | `src/packages/Signal.lua` | `ReplicatedStorage.packages.Signal` | GoodSignal by stravant | Not recorded. The usual GoodSignal header (author and license) was stripped. | MIT upstream; the notice is missing from the copy |
| Trove | `src/packages/Trove.lua` | `ReplicatedStorage.packages.Trove` | Trove by Stephen Leitnick (sleitnick/RbxUtil) | Not recorded. Header: "October 16, 2021". | MIT upstream (RbxUtil) |
| TestEZ | `tests/TestEZ/` | `TestService.TestEZ` | Roblox/testez | Not recorded. The API matches the 0.4.x line. | Apache-2.0 upstream |

## Notes

- **Trove is a 2021 copy.** Current RbxUtil Trove releases have changed since then (typed API and more helpers). Code here relies on `Trove.new`, `Add`, `Connect`, `Extend`, `Clean`, `Destroy` and on `Remove` also cleaning up the removed object. Check those semantics before upgrading.
- **ShapecastHitbox has one local change:** `Settings.lua` sets `Debug_Visible = false`. The vendored copy originally had `true`, which draws debug geometry for every cast on every client. Keep this change through any upgrade.
- **TestEZ is test-only.** It lives under `tests/` so it is mapped into `TestService` and never replicated to clients through `ReplicatedStorage.packages`.
- **Licenses.** Where an upstream license requires its notice to be kept (MIT, Apache-2.0), restore the notice when the package is next updated: for example a `LICENSE` file beside each package, or the original header.
- These packages were not upgraded as part of this documentation. Upgrades should be their own change, followed by a Studio TestEZ run.

## Recommendation: manage packages with Wally

[Wally](https://github.com/UpliftGames/wally) would replace these hand copies with pinned versions plus a lockfile, and would keep upstream license files with each package. Wally is already installed at `~/.rokit/bin/wally`. This project pins its tools with Aftman (`aftman.toml`), so Wally first has to be added to a tool manifest: either add it to `aftman.toml` or run `rokit add UpliftGames/wally`. Running `wally` with no manifest fails with "Failed to find tool 'wally' in any project manifest file".

A migration outline:

1. Add a `wally.toml` with the runtime packages under `[dependencies]` (for example `sleitnick/trove`) and TestEZ under `[dev-dependencies]` (`roblox/testez`). Check each package's Wally name and pick the version deliberately. Wally's `sleitnick/signal` is a fork of GoodSignal with a slightly different API, and ShapecastHitbox may not be published on Wally at all. Either can stay vendored.
2. Run `wally install`, then point `default.project.json` at the generated `Packages/` and `DevPackages/` folders, keeping `DevPackages` under `TestService`.
3. Keep the `Debug_Visible = false` setting: set it at runtime through `ShapecastHitbox.Settings`, or keep ShapecastHitbox vendored.
4. Run the Studio TestEZ suite (`docs/TESTING.md`).
