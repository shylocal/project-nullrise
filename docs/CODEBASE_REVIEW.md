# Codebase review

This review recorded actionable engineering constraints from before the refactor. **Every item is now done.** Each entry says where it was done; [ARCHITECTURE.md](ARCHITECTURE.md) describes the result, and the "§14.N" numbers refer to its list of intentional behaviour changes.

## Tier 1: combat

### Mandatory hit evidence: **Done**
`CombatValidation.ValidateHit` rejects `Hit` packets without a tagged hitpoint `Attachment` and a finite impact `Vector3`. It then checks the hitpoint-to-impact distance, target range, a horizontal facing cone and line of sight. Line of sight always runs attacker root to target root (head to head as a fallback), and the impact must lie on the target's bounding box. Every rejection returns a `RejectReason` that Telemetry counts.
Where: `src/server/services/CombatValidation.lua`; ARCHITECTURE.md §6.4; `CombatValidation.spec`.

### Weapon-swap timing: **Done**
Weapon changes reset only the combo sequence. They keep `NextAttackAt` and the remote budget, so alternating weapons cannot refresh the attack cooldown.
Where: `CombatService` (`EquippedChanged` → `_reset_attack_sequence`); ARCHITECTURE.md §6.3; `CombatService.spec`.

### Server timing: **Done**
The global timing constants were replaced by per-move `HitStartAt`, `HitWindow`, `MinDuration` and `Hold.MaxHoldTime` in the weapon definitions, with the formulas in `MoveKinds`. Early HitStarts are armed, hits during an armed HitStart are buffered (§14.8, §14.14), long charges deal damage, and every Attack request gets exactly one `AttackAccepted` or `AttackRejected`. Light-attack cooldowns were later raised by user decision (§14.22).
Where: `src/shared/weapons/{Fists,Katana}.lua`, `src/server/services/{CombatService,MoveKinds}.lua`; ARCHITECTURE.md §6.1, §6.3; `CombatService.spec`, `CombatHitBuffer.spec`, `MoveKinds.spec`, `WeaponGolden.spec`.

### Multi-hit behavior: **Done**
The client forwards only living Humanoid models (`CharacterQuery.resolve_alive`). `Hit` packets are budgeted generously (60/s, burst 16) rather than throttled, so two targets hit on the same frame both count. They are bounded by the hit window, per-target dedupe, `MaxHitsPerAttack` (8), `MaxHitRequestsPerAttack` (12) and `MaxRejectsPerTarget` (2).
Where: `CombatService._validate_hit`, `Config.Network.RemoteBudget`; ARCHITECTURE.md §5.3, §6.3.

### Cleanup: **Done**
All per-player combat state lives on the `PlayerSession` (`session:Set(CombatService, state)`) and is destroyed with it. Character removal clears the active move and the cooldown anchor.
Where: `PlayerService` / `PlayerSession` components; ARCHITECTURE.md §4.

## Tier 2: structure: **Done**

Parkour is split into queries, a typed state machine (`State.enter` with a transition table), ledge detection, ledge and corner traversal, vault traversal and math. All Workspace queries go through `QueryContext`. Hang, mantle and vault data exist only inside their state.
Where: `src/client/controllers/ParkourController/`; ARCHITECTURE.md §7.1.

Combat is split into input buffering (`AttackInput`), lifecycle orchestration (`AttackLifecycle`) and hitbox sampling (`Hitbox`, reused per equip). The animation layers sit over a shared `TrackCache`.
Where: `CombatController/`, `AnimationController/`; ARCHITECTURE.md §6.2.

## Runtime contracts: **Done**

`default.project.json` declares `ReplicatedStorage.packages`, `ReplicatedStorage.ui`, `ServerStorage.weapon_models` and the remotes. Packages come from Wally (Trove, TestEZ) or are vendored with recorded provenance (Signal, ShapecastHitbox, ProfileStore). TestEZ is a Wally dev dependency mapped under `TestService` and never replicated.

Authored assets remain Studio-only by design, but are verified at boot: `AssetContracts` checks the weapon templates and `UiContracts` checks the UI templates. `AnimationContracts` checks move timing against the baked animation manifest. `Catalog` serves only the allowlist (Fists, Katana), validates every move, and raises every error at once.
Where: `src/server/AssetContracts.lua`, `src/client/UiContracts.lua`, `src/shared/weapons/{Catalog,Validator,AnimationContracts}.lua`; ARCHITECTURE.md §6.1, §9; [DEPENDENCIES.md](DEPENDENCIES.md), [VENDORED.md](VENDORED.md).

## Input: **Done**

PC, touch and gamepad adapters feed `InputController`, which de-duplicates by device family and physical source. Mobile exposes parkour actions, gamepad has its own adapter, PC hotkeys 1–9 select slots 1–9, and a focus loss releases every action.
Where: `src/client/input/`, `InputController.lua`; `InputController.spec`.

## Authority: **Done**

Combat, inventory and persistence are server-owned. Movement and parkour are client-owned and observed by `MovementValidation`, with limits derived from config by `Envelope`.
Where: [THREAT_MODEL.md](THREAT_MODEL.md).

## Hygiene: **Done**

- All tuning lives in one validated, deep-frozen config tree (`src/shared/config`), and no `x or default` fallbacks remain.
- The unused `VaultMaxHopDistance` is gone, and `ShapecastHitbox` debug drawing is off.
- Every module under `src/**` and `tests/**` is `--!strict` (vendored code excepted). The gate (`scripts/analyze.sh`, luau-lsp plus selene) reports zero findings.
- Dead code was removed in Phase 3. History comments were replaced by invariant comments.

The Katana's shared `Idle`/`Sprint` animation id is now declared intentional (`Sprint.SharedWith = "Idle"`, enforced by the Validator). Replace it if a dedicated Sprint asset is made.
