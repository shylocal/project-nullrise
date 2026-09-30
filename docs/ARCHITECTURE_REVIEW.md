# Architecture Review (September 2026)

## Scope

This is a source-level review of the current `main` snapshot, focused on maintainability and scaling risks before the game grows. It is not a claim that the game has been load-tested or fully exercised in Studio. The review sampled the client/server entrypoints, player/session lifecycle, inventory, combat validation, input, character composition, project mapping, and the existing test guide.

## Summary

The project has a coherent foundation: native Luau, explicit dependencies, narrow gameplay modules, shared protocol/catalog definitions, server-side combat validation, and deliberate teardown. The current architecture is not in need of a framework rewrite. The main risk is that a few convenient APIs and lifecycle patterns could become implicit contracts as more systems are added.

## Findings (ordered by risk)

### 1. Inventory exposes mutable server-owned state

**Evidence:** `InventoryService:Get(player)` returns the internal inventory table directly, including its mutable `Slots` table. Replication correctly creates a detached snapshot, but callers of `Get` can bypass `SetSlot` validation, replication, and `Changed` notifications by mutating the returned object.

**Why it matters:** As shops, loot, persistence, crafting, and trading are added, direct mutation can create state that is valid locally but never replicated or announced. It also makes it difficult to reason about which methods enforce invariants.

**Recommendation:** Prefer narrow read APIs (`GetSlot`, `GetSelectedSlot`, `GetSelectedId`, `Has`) and remove or privatize `Get` if no external caller needs the whole structure. If a snapshot API is required, return a detached copy and name it explicitly (for example, `GetSnapshot`). Before changing this, audit all call sites and add a regression spec proving callers cannot mutate authoritative state through a read result.

**Priority:** High; address before persistence or trading work.

### 2. Player/session lifecycle is duplicated across services

**Evidence:** `PlayerService`, `InventoryService`, `WeaponService`, and `CombatService` each subscribe to player lifecycle signals and separately process already-connected players. Per-player Troves and idempotency guards are already used in several places.

**Why it matters:** This is manageable at the current scale, but every new player-scoped service adds another join/leave path, another ordering dependency, and another opportunity to miss cleanup. The current code's explicitness is valuable, so a generic service framework would likely cost more than it saves.

**Recommendation:** Keep `PlayerService` as the session owner. For future systems, pass a session-scoped lifecycle signal/API or make the session the composition point for player-owned state. Do not refactor all existing services at once; migrate one new or low-risk service first, with join-after-start, existing-player, respawn, and removal tests.

**Priority:** Medium; establish the pattern before adding several more player-scoped systems.

### 3. Runtime construction is manually repeated

**Evidence:** Client and server entrypoints both use staged locals, `pcall`, reverse-order cleanup on partial initialization failure, a runtime `Destroy`, and `script.Destroying` teardown.

**Why it matters:** The pattern is sound and the ordering is documented, but changes to startup dependencies require careful edits in multiple places. A missed cleanup entry can leak resources after a constructor failure.

**Recommendation:** Do not introduce a general dependency-injection container. If entrypoints grow, extract only a tiny local construction/cleanup helper or keep a clearly ordered constructor list. Preserve explicit dependency wiring and reverse-order destruction. Add a failure-injection test only if startup construction becomes more complex.

**Priority:** Low; current implementation is readable and appropriate.

### 4. Combat remote validation is strong in structure, but deserves adversarial integration coverage

**Evidence:** The server checks action names, per-action minimum intervals, active attack identity/window, current living character, equipped weapon/hitbox identity, target model/humanoid, range, finite vectors, tagged attachments, and an optional obstruction raycast. The test guide correctly distinguishes isolated TestEZ coverage from live Studio combat timing.

**Why it matters:** Remote combat is an adversarial boundary. Unit tests cannot fully model replication delay, event ordering, physics, or malicious clients. Optional hit metadata also means there are multiple validation paths that should remain intentional.

**Recommendation:** Preserve server authority. Add a small Studio multiplayer checklist (and, where practical, deterministic validation specs) for omitted hit metadata, stale character/weapon reports, repeated target reports, obstruction, extreme positions, and rapid event sequences. Avoid making the client authoritative for damage or hit confirmation.

**Priority:** High for any combat expansion; this is a coverage priority, not evidence of a confirmed exploit.

### 5. Controller composition is explicit, but character readiness assumptions should stay visible

**Evidence:** `CharacterController` watches for Humanoids and owns movement, parkour, combat, animation, and weapon controllers. It constructs several controllers immediately, while individual modules also look up character components themselves.

**Why it matters:** Roblox character descendants can arrive asynchronously. Multiple modules independently waiting for or observing readiness can become inconsistent as more character-bound systems are introduced.

**Recommendation:** Keep character composition centralized. If a future feature needs guaranteed Humanoid/root readiness, introduce one small readiness contract in the character/session layer and pass the resolved dependency to that feature; do not add waits indiscriminately or force every controller to depend on a large shared context.

**Priority:** Medium; revisit when adding systems with stricter rig requirements.

### 6. Performance work should remain measurement-led

**Evidence:** Parkour query profiling is opt-in and reports query counts and elapsed search time. The testing guide records prior Studio samples where mantle sampling/raycast counts improved, while `ModelBoundsQueries=0` in the supplied samples.

**Why it matters:** This is a good example of avoiding speculative caching. Caching geometry or reducing probes without map-specific evidence can break stacked ledges, corners, or landing safety.

**Recommendation:** Keep profiling opt-in. Capture representative worst-case maps and traversal paths before optimizing. Track query counts, frame-time impact, and correctness together; retain conservative checks until a targeted test demonstrates equivalence.

**Priority:** Medium; repeat as map complexity increases.

## What I would not do

- Do not replace the architecture with a large framework or generated layer.
- Do not split modules solely to reduce line count.
- Do not add broad caching to parkour queries without profiling evidence.
- Do not centralize every setting into one global configuration file; domain-local configuration is easier to own.
- Do not change remote names or argument order without treating them as a versioned client/server contract.

## Suggested sequence

1. Audit callers of `InventoryService:Get`; if it is not needed, replace it with read-only accessors and add a mutation-isolation spec.
2. For the next player-scoped feature, choose and document one session ownership pattern rather than copying another independent lifecycle scaffold.
3. Add multiplayer Studio cases for combat event ordering and adversarial payloads before expanding combat mechanics.
4. Re-profile parkour on larger, representative maps before considering caching or reducing spatial queries.
5. Revisit entrypoint construction only when the number of owned systems makes the current explicit teardown lists cumbersome.

## Review limitation

This review is based on the files inspected in the repository snapshot and the testing history documented in `docs/TESTING.md`. It does not establish current live-server performance, exhaustive call-site usage, or a passing result for the latest pending Studio input reconciliation patch. Run the documented Studio suite and gameplay checks after syncing any subsequent changes.


## Follow-up implementation: inventory read isolation

The repository-wide server source audit found no callers of `InventoryService:Get(player)` outside its definition. The public method is retained for compatibility, but now returns the same detached snapshot shape used for replication rather than the authoritative inventory table. This preserves read access to `Slots` and `SelectedSlot` while preventing mutation through that API from silently bypassing service invariants. The existing inventory snapshot spec now also checks that the public view is detached. The implementation and test are committed separately on `main`.

This is intentionally a narrow first step. The lifecycle consolidation, combat adversarial Studio scenarios, and parkour profiling recommendations remain follow-up work; this repository integration cannot run Roblox Studio or validate live physics/network behavior. Use the checklist in `docs/TESTING.md` after syncing the changes.
