# Running Tests

The project uses TestEZ for small, deterministic Luau tests. Tests are mapped into Roblox `TestService` and are not run automatically during game startup.

## Install TestEZ once

The project avoids Wally and keeps third-party Roblox modules in the existing Roblox-managed `ReplicatedStorage.packages` folder.

1. Download the source for [Roblox/TestEZ v0.4.2](https://github.com/Roblox/testez/releases/tag/v0.4.2).
2. Add the release's `src` tree as a package named `TestEZ` under `ReplicatedStorage.packages`, using the same Roblox package workflow as the project's other packages. The root module must be `TestEZ` (from `src/init.lua`), with its child modules and `Reporters` folder preserved.
3. Confirm that this path exists in Studio: `ReplicatedStorage.packages.TestEZ`.

TestEZ's upstream repository is archived, so keep the dependency pinned to the selected release rather than tracking a moving branch. See the [upstream repository](https://github.com/Roblox/testez) for source and licensing details.

## Run the suite in Studio

1. From the project root, start Rojo with `rojo serve`.
2. Open the place in Roblox Studio and connect the Rojo plugin to the running server so the current source is synced.
3. Start a local test session with **Test > Play** (or **Play**).
4. Open the Studio Command Bar and set its execution context to **Server**.
5. Run:

```lua
require(game:GetService("TestService").tests.RunTests).Run()
```

TestEZ's text reporter writes the test results to the Output window. The runner returns TestEZ's results object. It also checks `RunService:IsStudio()`, so it cannot be invoked in a published server.

## Add a test

Create a ModuleScript file ending in `.spec.lua` under `tests/specs`. Rojo maps the `tests` folder into `TestService`, and TestEZ recursively discovers spec ModuleScripts under `TestService.tests.specs`.

A spec module returns a function and uses TestEZ's `describe`, `it`, and `expect` functions:

```lua
return function()
	describe("Example", function()
		it("checks a behavior", function()
			expect(2 + 2).to.equal(4)
		end)
	end)
end
```

Keep unit tests deterministic and self-contained. Prefer testing pure functions and validation rules first. Tests that create Instances, connect signals, or mutate services should clean up what they create and avoid firing live remotes or depending on the current map.

## Current starter coverage

- `Vector.spec.lua`: verifies that `Vector.flatten` removes Y while preserving X/Z.
- `WeaponCatalog.spec.lua`: verifies built-in melee definitions, unknown/invalid lookups, and melee classification.

These starter tests are source setup only until TestEZ is installed in Studio and the runner is executed. Roblox Studio execution is not performed by the repository edit itself.
