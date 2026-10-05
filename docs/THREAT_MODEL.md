# Threat model

## Trust boundary

All client input, client-selected inventory actions, client-reported hit targets, hitpoint attachments, impact positions, and movement state are untrusted.

Combat crosses the trust boundary through `ReplicatedStorage.remotes.Combat`. The server resolves the player's current character and equipped weapon, checks the attack sequence and cooldown, owns the allowed hit window, validates the target Humanoid and authored hitpoint attachment, checks range and facing, performs a line-of-sight raycast, and only then applies server-side damage.

**Fixed:** line of sight is now always checked from the attacker's root to the target's root (head to head as a fallback), so a hit through a wall is rejected even when the hitpoint-to-impact segment is clear. The reported impact must also lie on the target's bounding box (within `HitPositionTolerance`). Attack rate is enforced per move through `MinDuration` (Fists lights 0.35s, Katana lights 0.6s, Heavies 0.6s), and hit timing through each move's `HitStartAt`/`HitWindow`. An early `HitStart` is armed and only opens the window at `HitStartAt`; hits that arrive while it is armed are buffered (one per target, at most `MaxHitRequestsPerAttack`) and validated through the normal path when it opens. After a Heavy held past its marker is released, the next Heavy's hit cannot open before `release + HoldTime + HitStartAt - TimingTolerance`, so a forged release cannot stack two Heavy hits within a few frames. Move ids are re-checked against the equipped weapon, the combo cursor and the bindings on every request, so replaying or forging ids gains nothing.

Lag compensation (`PositionHistory`) only relaxes the reach and impact-on-body checks, against the target's recorded position at most `Combat.LagCompensation.MaxRewind` (0.3s) ago; every other check runs unchanged. Damage is applied only by `DamageService`, whose policies can block it, and `HitConfirmed` is sent only for damage actually dealt.

Inventory contents are persisted in a session-locked ProfileStore profile. Clients can only select (`SelectSlot`, `SelectUid`); granting and removing items is server-only. On load, structurally corrupt slot records (bad slot key, malformed record, duplicate Uid) are dropped. Records this build does not recognise (an unknown ItemId, a slot above `MaxSlots`) are kept as saved but never replicated or equipped, so a rollback cannot delete items. A profile with a newer, missing or invalid `Version`, or one whose migration fails, is released untouched and the player is kicked on a live server. Another server taking the session lock kicks the player from this one, so two servers never write the same profile.

Inventory selection crosses a separate remote. The server validates slot/item values and charges every request against the per-player `RemoteBudget` (token buckets per action plus a global bucket, `Config.Network.RemoteBudget`). **Fixed:** slots are integers in `1..Config.Inventory.MaxSlots` (9); non-integer, huge, NaN and infinite slots are rejected, and uids are strings of at most `MaxItemIdLength` characters. Weapon models are kept server-side in `ServerStorage` and only attached to the character after server validation. **Fixed:** the server refuses to attach weapons to non-R6 rigs, so such characters cannot attack.

## Remote abuse and telemetry

- Every inbound action on `Combat` and `Inventory` is charged to `RemoteBudget` before it is handled. Events that clients fire at the server-to-client remotes `Weapon` and `CombatFx` are drained by `InboundSink` and charged as unknown actions, so they cost global budget instead of queueing on the server.
- Non-string actions, malformed arguments and unknown actions are dropped and counted, never echoed. A malformed or budget-dropped `Attack` gets at most one reply per `RejectReplyInterval`.
- Telemetry details sent to AnalyticsService are always server-chosen (weapon ids, budget keys, constants). An unknown action is recorded as `<Remote>.<unknown>`; Studio alone prints the client's raw text. Per-player keys are capped (64) and details truncated (48 characters).
- The suspicion score is informational: nothing kicks or punishes on it.

## Client-authoritative movement

Parkour and movement still run on the client by design. `ParkourController` writes the character root `CFrame`, and `MovementController` writes `Humanoid.WalkSpeed`. The server does not attempt to reproduce the parkour controller or approve every movement frame.

A server-side `MovementValidation` observer now watches the replicated character root and classifies only extreme anomalies:

- `TeleportDistance`: displacement more than 40 studs beyond the allowed speed envelope.
- `HorizontalSpeed`: more than 98.5 studs/s horizontally (derived: `Envelope.HorizontalMargin` times the fastest legitimate source, see `src/shared/config/Envelope.lua`).
- `VerticalSpeed`: more than 240 studs/s upward (derived the same way from `MaxJumpVelocity`), or faster downward than free fall allows: `sqrt(240^2 + 2 * Workspace.Gravity * h)`, where `h` is the height fallen since the last apex.

**Fixed:** long falls no longer produce false `VerticalSpeed` reports. Displacement is judged over a sliding window of up to 1 second, and only once the window covers at least 0.25 seconds, so a burst of delayed replicated positions is averaged over the time it covers.

The observer resets its baseline when a character spawns/removes and ignores the first 1.5 seconds of each character's life while Roblox settles spawn physics. During that grace period it continues refreshing its baseline without classifying movement. It also ignores samples separated by more than 0.5 seconds so server stalls do not become false positives.

This validator is **observe-only**. It records a per-player violation count, a Telemetry counter and a rate-limited server warning; it does not kick, reposition, or otherwise mutate the character. The thresholds are intentionally loose enough to encompass the authored vault/top-hop movement envelopes while still providing server-side evidence when a client makes implausible jumps.

## What this does and does not protect

The observer improves detection and logging but does not make movement authoritative. A cheater can still move within the allowed envelope, exploit physics edge cases, or alter movement in ways that are not visible as a simple position delta.

Combat validation should therefore continue to be treated as a forged-packet defense rather than a complete anti-cheat boundary. Because combat range is measured from the server-observed character position, an attacker who can produce an accepted but dishonest movement state can still influence that input to combat.

## Multiplayer validation plan

Use a two-player Studio server test to verify the boundary rather than assuming single-player TestEZ coverage proves it.

1. Spawn two players and perform ordinary walking, sprinting, jumping, vaulting, top-hop, hanging, and mantling with one player while the other remains nearby.
2. Confirm neither player produces `MovementValidation` warnings during normal traversal and that both players remain independently controllable.
3. In the **server** command bar only, move a test character by a deliberately extreme CFrame delta and verify that the server prints one rate-limited `[MovementValidation]` warning for the affected player.
4. Respawn that player and verify the movement baseline resets without carrying the prior violation count into the new character.
5. Repeat with two players so the observer is shown to maintain independent state per player.

These scenarios validate observability and lifecycle handling. They do not claim to prove resistance to a real exploit client.

## Accepted prototype trade-off

Client-authoritative traversal keeps the prototype responsive and avoids a second server simulation. The current server observer establishes a measurable security boundary without silently changing gameplay.

This remains unsuitable as a full trust model for ranked, competitive, economy-sensitive, or otherwise adversarial multiplayer systems.

## Future server-authoritative work

A stronger movement security pass should validate a compact set of server-known invariants rather than reproduce the entire parkour controller. Candidates include explicit server-approved teleports, stronger displacement/velocity envelopes derived from the currently permitted movement mode, server-issued traversal permissions for high-value interactions, and corrective action after repeated violations.

## What this document does not claim

- The client cannot cheat movement; it can.
- Studio TestEZ results prove published-server security; they do not.
- The movement observer catches every exploit; it does not.
- Combat validation protects against every networking exploit; it does not.
- UI state is authoritative; the server weapon event is authoritative.
