# Codebase review

This review records current, actionable engineering constraints. It is intentionally descriptive rather than a session log. Items marked **Fixed** have been addressed in code.

## Tier 1: combat

### Mandatory hit evidence
`CombatValidation` now rejects `Hit` packets without both a tagged hitpoint `Attachment` and a finite impact `Vector3`. The server always checks hitpoint-to-impact distance, target range, a horizontal facing cone, and an obstruction raycast. **Fixed:** the obstruction check now always runs attacker root to target root (head to head as a fallback), and the impact must lie on the target's bounding box.

### Weapon-swap timing
Weapon changes reset only combo sequence. They no longer clear `NextAttackAt` or remote-rate-limit timestamps, so alternating weapons cannot refresh the attack cooldown.

### Server timing
The server accepts hit activation only in a bounded start grace period and creates its own hit-window expiry. The client cannot extend a hit window to the full attack timeout. **Fixed:** the global timing constants are replaced by per-attack `HitStartAt`, `HitWindow` and `MinDuration` (plus `MaxHoldTime` for charges) in the weapon definitions. Long charges now deal damage, and every Attack request receives exactly one `AttackAccepted`/`AttackRejected`.

### Multi-hit behavior
The client forwards only living Humanoid models. The server still deduplicates targets per attack and caps the total number of successful targets in one attack. ~~The hit remote uses a shorter transport throttle so two legitimate frames can be reported.~~ **Fixed:** `Hit` packets are no longer throttled, so two targets hit on the same frame both count. They are bounded by the hit window, per-target dedupe, `MAX_HITS_PER_ATTACK` and `MAX_HIT_REQUESTS_PER_ATTACK`.

### Cleanup
Player removal deletes active attacks, combo state, cooldown state, and rate-limit state instead of re-adding a default combo entry.

## Tier 2: structure

Parkour is decomposed into queries, state, ledge detection, ledge traversal, vault traversal, and math modules. `LedgeDetection` owns candidate search/classification while `LedgeTraversal` owns traversal state and movement side effects. Hanging and mantling execution data lives in explicit `ParkourState` records, and the controller no longer acts as a forwarding shell for most traversal/query methods.

Combat has the useful split between input buffering, lifecycle orchestration, and hitbox sampling. Animation submodules are still thin adapters, which is acceptable until they acquire independent policy.

## Runtime contracts

`default.project.json` declares `ReplicatedStorage.packages`, `ReplicatedStorage.ui`, and `ServerStorage.weapon_models` so their existence is visible in the source layout. The repository still needs approved package contents and authored assets before it can be considered fully self-contained.

`WeaponService` reads weapon templates from `ServerStorage`, and the server registers the `Climbable` collision group at startup. Shared melee definitions are validated by `src/shared/weapons/Validator.lua` when loaded. **Fixed:** `Catalog` serves only an explicit allowlist (Fists, Katana), validates every attack in the combo, and errors at startup on a missing or invalid definition. Vendored package provenance is documented in `docs/VENDORED.md`, and TestEZ moved out of `ReplicatedStorage.packages` into `tests/TestEZ`.

## Input

PC, touch, and gamepad adapters feed a single logical input layer. Mobile now exposes parkour actions, and gamepad has an explicit adapter instead of only mapping input types.

## Authority

Combat, inventory selection validation, and weapon attachment are server-owned. Movement and parkour remain client-owned; that boundary is documented in `docs/THREAT_MODEL.md`.

## Hygiene

Parkour configuration has a single source in `Config.lua`; avoid new `Config.X or default` fallbacks. **Fixed:** the unused `VaultMaxHopDistance` was removed, mantle duration and top-hop timeout moved into `Config.lua`, the remaining `or <default>` fallbacks were removed from parkour and combat, and `ShapecastHitbox` debug drawing is off. Remove history comments, normalize lifecycle flag naming, and keep documentation tied to the actual code.

Known data issue: the Katana currently uses the same animation ID for `Idle` and `Sprint`. This review does not invent a replacement asset ID; fix it when the intended Sprint asset is identified.

Known dead-code candidates such as the unused `CharacterTrove` claim in the previous review were rechecked against current source and were not removed when they are actually used. This review prefers verified cleanup over checklist-driven deletion.