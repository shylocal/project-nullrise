# project-nullrise

A Roblox game built with native Luau and Roblox primitives.

## Philosophy

Nullrise intentionally avoids a heavyweight game framework. The project uses ordinary ModuleScripts, Roblox services, explicit dependencies, and small utility packages where they provide real value.

### Core choices

- Native Luau
- Rojo for project syncing
- Wally for packages
- Trove for cleanup/lifecycles
- Signal for Lua-side events
- Explicit module dependencies
- Roblox RemoteEvents/RemoteFunctions for networking when needed

No roblox-ts, Flamework, Reflex, or generated framework layer.

## Project layout

```
src/
├── client/
│   ├── controllers/
│   └── init.client.lua
├── server/
│   ├── services/
│   ├── systems/
│   └── init.server.lua
└── shared/
    ├── config/
    ├── modules/
    └── types/

Packages/
default.project.json
wally.toml
```

## Setup

Install the project tools, then run:

```sh
wally install
rojo serve
```

Open the generated Rojo project in Roblox Studio and connect to the running Rojo server.

## Conventions

Prefer plain modules over abstractions.

Use a class-style module only when an object has meaningful state and lifecycle. Give objects an explicit `Destroy` method and use Trove when they own connections, instances, threads, or other disposable resources.

Use Signal for internal Lua events. Use Roblox remotes for client/server communication.

Keep game-specific concepts close to the gameplay they belong to; don't create a service or controller just because the folder exists.
