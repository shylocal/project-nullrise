# Threat model

## Trust boundary

All client input, client-selected inventory actions, client-reported hit targets, hitpoint attachments, and impact positions are untrusted.

Combat crosses the trust boundary through `ReplicatedStorage.remotes.Combat`. The server resolves the player's current character and equipped weapon, checks the attack sequence and cooldown, owns the allowed hit window, validates the target Humanoid and authored hitpoint attachment, checks range and facing, performs a line-of-sight raycast, and only then applies server-side damage.

Inventory selection crosses a separate remote. The server validates slot/item values and rate-limits selection requests. Weapon models are kept server-side in `ServerStorage` and only attached to the character after server validation.

## Client-authoritative movement

Parkour and movement currently run on the client by design. `ParkourController` writes the character root `CFrame`, and `MovementController` writes `Humanoid.WalkSpeed`. There is no server-side movement validator in this project.

This means a malicious client can potentially teleport, move faster than intended, bypass parkour constraints, or otherwise falsify movement. The current combat validator should therefore be understood as protection against forged combat packets, not as a complete anti-cheat boundary: if a future exploit can manipulate the server-observed character position, any combat range check based on that position inherits the risk.

## Accepted prototype trade-off

Client-authoritative traversal keeps the prototype responsive and avoids a second server simulation. It is acceptable only while the game treats movement abuse as out of scope. The threat model must change before ranked, competitive, economy-sensitive, or otherwise adversarial multiplayer systems depend on trustworthy movement.

## Future server-authoritative work

A movement security pass should validate a compact set of invariants rather than attempt to reproduce the entire parkour controller on the server. Candidates include displacement/velocity envelopes, humanoid state transitions, teleport detection with legitimate respawn/teleport exemptions, and server-issued traversal permissions for high-value interactions.

## What this document does not claim

- The client cannot cheat movement; it can.
- Studio TestEZ results prove published-server security; they do not.
- Combat validation protects against every networking exploit; it does not.
- UI state is authoritative; the server weapon event is authoritative.