# project-nullrise

A Roblox game built with native Luau and Roblox primitives.

## Philosophy

Nullrise intentionally avoids a heavyweight game framework. The project uses ordinary ModuleScripts, Roblox services, explicit dependencies, and small utility packages where they provide real value.

### Core choices

- Native Luau
- Rojo for project syncing
- Roblox-managed package assets
- Trove for cleanup/lifecycles
- Signal for Lua-side events
- Explicit module dependencies
- Roblox RemoteEvents/RemoteFunctions for networking when needed

No roblox-ts, Flamework, Reflex, Wally, or generated framework layer.

## Project layout

```
src/
├── client/
│   ├── controllers/
│   │   ├── PlayerController.lua
│   │   ├── CharacterController.lua
│   │   └── WeaponController.lua
│   └── init.client.lua
├── server/
│   ├── services/
│   │   └── WeaponService.lua
│   ├── systems/
│   └── init.server.lua
└── shared/
    ├── config/
    ├── modules/
    └── types/

default.project.json
```

## Setup

Use Rojo to sync the project into Roblox Studio.

```sh
rojo serve
```

Install and manage third-party packages through the Roblox package workflow rather than a repository-side package manager.

## Conventions

Prefer plain modules over abstractions.

Use a class-style module only when an object has meaningful state and lifecycle. Give objects an explicit `Destroy` method and use Trove when they own connections, instances, threads, or other disposable resources.

Weapon definitions are data modules under `src/shared/weapons`. Client controllers interpret them for presentation; server services remain authoritative over gameplay state.

Use Signal for internal Lua events. Use Roblox remotes for client/server communication.

Keep game-specific concepts close to the gameplay they belong to; don't create a service or controller just because the folder exists.
