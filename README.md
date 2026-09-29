# project-nullrise

A Roblox game built with native Luau and Roblox primitives.

## Philosophy

Nullrise intentionally avoids a heavyweight game framework. The project uses ordinary ModuleScripts, Roblox services, explicit dependencies, and small utility packages where they provide real value.

### Core choices

- Native Luau
- Rojo for project syncing
- Roblox-managed package assets
- Trove for cleanup and lifecycles
- Signal for Lua-side events
- Explicit module dependencies
- Static Roblox remotes for networking

No roblox-ts, Flamework, Reflex, Wally, or generated framework layer.

## Project layout

```
src/
├── client/
│   ├── controllers/
│   │   ├── AnimationController/
│   │   │   ├── Combat.lua
│   │   │   ├── Movement.lua
│   │   │   ├── Weapon.lua
│   │   │   └── init.lua
│   │   ├── CombatController/
│   │   │   ├── Hitbox.lua
│   │   │   └── init.lua
│   │   ├── UIController/
│   │   │   ├── Hitmarker.lua
│   │   │   ├── WeaponMenu.lua
│   │   │   └── init.lua
│   │   ├── CharacterController.lua
│   │   ├── InputController.lua
│   │   ├── MovementController.lua
│   │   ├── PlayerController.lua
│   │   └── WeaponController.lua
│   ├── input/
│   │   ├── Mobile.lua
│   │   └── PC.lua
│   └── init.client.lua
├── server/
│   ├── services/
│   │   ├── CombatService.lua
│   │   ├── CombatValidation.lua
│   │   ├── InventoryService.lua
│   │   ├── PlayerService.lua
│   │   ├── PlayerSession.lua
│   │   ├── WeaponAttachment.lua
│   │   └── WeaponService.lua
│   └── init.server.lua
└── shared/
    ├── input/
    │   └── Actions.lua
    ├── movement/
    │   └── Config.lua
    ├── network/
    │   └── Protocol.lua
    └── weapons/
        ├── Catalog.lua
        ├── Fists.lua
        └── Katana.lua

default.project.json
```

Large responsibilities are split by domain rather than by arbitrary size. For example, animation has separate movement, weapon, and combat modules; combat owns its hitbox adapter; and server services delegate focused validation, session, and attachment work.

## Parkour

Parkour tuning lives in `src/client/controllers/ParkourController/Config.lua`. While hanging, holding Sprint increases A/D traversal speed without changing the existing ledge-clearance and corner-lock checks.

On the ground, vaulting is explicitly requested with Space while sprinting and moving into a suitable collidable, non-climbable obstacle. It is not triggered automatically or restricted by the character's facing direction: detection follows movement direction and uses center-first detection with narrower side and height probes, plus a facing-direction fallback for diagonal approaches. The controller samples the obstacle top and checks available space before committing. Vaults prefer a brief hop to validated ground beyond the far edge, checking progressively farther landing points; only obstacles whose far side cannot be safely reached within the configured hop range fall back to a short hop onto the walkable top. The character clearance envelope is sampled along the arc to reject blocked landing or overhead space. If checks fail, the regular jump and ledge-grab behavior remain available.

Vault obstacle height and arc are configured up to about four studs by default. During the middle of the vault, HipHeight is smoothly reduced by a configurable 1 stud through most of the vault and restored by the landing; R6 rigs allow a small negative offset because their default HipHeight is often zero. The far-side hop distance is sized to allow narrow obstacles to be cleared even when detected near the full trigger range. Detection distance, landing gap, top inset, timing, cooldown, and sprint traversal multiplier are also configurable.

## Setup

Use Rojo to sync the project into Roblox Studio.

```sh
rojo serve
```

Third-party packages are managed through the Roblox package workflow rather than a repository-side package manager.

## Conventions

Prefer plain modules over abstractions.

Use a class-style module when an object has meaningful state and lifecycle. Give objects an explicit `Destroy` method and use Trove when they own connections, instances, threads, or other disposable resources.

Weapon definitions are data modules under `src/shared/weapons`. Resolve them through `Catalog.Get(weapon_id)` so client and server use the same discovery and type checks. A new melee weapon is added as a definition module plus its authored model/assets; avoid duplicating module lookup logic in controllers or services.

Remote action strings belong in `src/shared/network/Protocol.lua`. Treat those names and argument order as a client/server contract: update both ends together when changing a message.

Project-wide defaults belong in focused configuration modules. Per-character movement modifiers should use `MovementController:SetSpeeds(walk_speed, sprint_speed)` rather than writing directly to the Humanoid, so sprint blocking and the controller's state remain consistent.

Use Signal for internal Lua events. Use Roblox remotes for client/server communication. Keep server validation authoritative and do not trust client-reported combat state without validating it against the current session, equipped weapon, hitbox, and target.

Controllers and services own their connections and disposable instances through Trove and expose `Destroy()`. The client and server entrypoints define deterministic teardown order and invoke it when the entrypoint script is destroyed; dependents are cleaned up before the services they reference.

Keep game-specific concepts close to the gameplay they belong to. Extract a module when it represents a real responsibility or isolates a meaningful implementation detail, not simply to make a file shorter.
