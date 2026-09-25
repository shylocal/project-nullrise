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
│   │   ├── PlayerService.lua
│   │   ├── PlayerSession.lua
│   │   ├── WeaponAttachment.lua
│   │   └── WeaponService.lua
│   └── init.server.lua
└── shared/
    ├── input/
    │   └── Actions.lua
    └── weapons/
        └── Fists.lua

default.project.json
```

Large responsibilities are split by domain rather than by arbitrary size. For example, animation has separate movement, weapon, and combat modules; combat owns its hitbox adapter; and server services delegate focused validation, session, and attachment work.

## Setup

Use Rojo to sync the project into Roblox Studio.

```sh
rojo serve
```

Third-party packages are managed through the Roblox package workflow rather than a repository-side package manager.

## Conventions

Prefer plain modules over abstractions.

Use a class-style module when an object has meaningful state and lifecycle. Give objects an explicit `Destroy` method and use Trove when they own connections, instances, threads, or other disposable resources.

Weapon definitions are data modules under `src/shared/weapons`. Client controllers interpret them for presentation; server services remain authoritative over gameplay state.

Use Signal for internal Lua events. Use Roblox remotes for client/server communication.

Keep game-specific concepts close to the gameplay they belong to. Extract a module when it represents a real responsibility or isolates a meaningful implementation detail, not simply to make a file shorter.
