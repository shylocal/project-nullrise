# Adversarial review findings (post-refactor, ee75e22..b095845)

These came out of the read-only adversarial review. The Finish step verifies each finding, fixes the real ones with regression specs, and records the outcome here.

## Server and shared

No critical or high-severity findings.

1. **MEDIUM: A Heavy (Charge) move skips its own recovery, which allows a 45–60 damage burst.**
   - **Where:** `CombatService.lua:~515` sets `NextAttackAt = now + MinDuration` at move start, and nothing changes it on release (HitStart, `:~594/~611`). `MoveKinds.lua:~204-217` keeps the HitStart window open until MaxHoldTime (10s), and the server never checks `Hold.HoldTime`.
   - **Scenario (Katana):** `Attack(Heavy)` at t=0 sets NextAttackAt to 0.6. HitStart and Hit at 0.55 deal 30. `Attack(Heavy)` at 0.56 passes (0.56 + 0.1 tolerance ≥ 0.6), and HitStart and Hit at 0.61 deal another 30. That is 60 damage within about 50ms. This is not a regression; ee75e22 behaved the same.
   - **Fix:** for `Kind == "Charge"`, on HitStart/activation set `NextAttackAt = max(NextAttackAt, release + (MinDuration - HitStartAt))`. Optionally reject a HitStart before `StartedAt + Hold.HoldTime - tolerance`.
2. **MEDIUM: Load-time sanitising permanently deletes persisted items.**
   - **Where:** `Schema.lua:~403, ~440-451`, via `PlayerDataService.lua:~222`.
   - **Problem:** slots with an ItemId unknown to *this build*, or a key above *this build's* MaxSlots, are deleted from `Profile.Data`, and ProfileStore saves the deletion.
   - **Scenario:** a rolling update or a rollback can wipe newly shipped items.
   - **Fix:** never mutate persisted data for "unknown to this build". Filter those slots at runtime (`build_entries` / `weapon_id_of`) and keep them in the profile, or move them to `Inventory.Orphaned`. Drop only structurally corrupt records.
3. **LOW: A failed migration still writes to saved data.**
   - **Where:** `PlayerDataService.lua:~211-218`. `profile:Reconcile()` runs before `Schema.migrate` and mutates the data in place.
   - **Problem:** a newer-version profile gets stray V1 keys and is then saved by EndSession. A profile whose Version is missing or corrupt gets Version=1 and is then sanitised.
   - **Fix:** validate or migrate a copy first, and Reconcile only after a successful migrate.
4. **LOW: An error after the profile loads leaks the profile session.**
   - **Where:** `PlayerDataService.lua:~211-247` and `PlayerService.lua:~243`.
   - **Problem:** if anything throws between StartSessionAsync and session:Set, the component never completes, so OnPlayerRemoving never calls EndSession. The profile stays locked and autosaved, the player has no inventory, and a rejoin to the same server is kicked.
   - **Fix:** wrap the post-load block in a pcall that calls `profile:EndSession()` and then `_fail`.
5. **LOW: Client-controlled strings reach AnalyticsService.**
   - **Where:** `RemoteBudget.lua:~136`, where UnknownAction uses the raw action string as `detail`, and `Telemetry.lua:~213-216`, which sends it as `CustomField02`.
   - **Problem:** an attacker can pollute analytics custom-field cardinality and rate limits for the whole experience.
   - **Fix:** log a constant such as `"<unknown>"` for client-supplied details, and keep the raw text only in the Studio print.
6. **LOW (minor):** the `Weapon` and `CombatFx` remotes have no OnServerEvent handler, so clients firing them fill the engine queue and spam warnings into server logs. Fix: a no-op handler that counts UnknownAction.
7. **LOW (minor):** `DamageService._recent` (`:~317-326`) never frees the record for an unparented, but not destroyed, non-player target. This only matters for NPCs.

**Checked and found sound:** remote argument validation; budgets and the reply throttle; replayed or forged move ids; damage without a valid move; hit-buffer caps; walls and lag-comp rewind (server-measured ping, clamped to 0.3); lifecycle (leaving mid-move, mid-load, session steal, BindToClose); Runtime teardown; join order; inventory dupes; Studio mock; empty weapon_models; Telemetry memory bounds; Wally mapping; no combat regressions versus ee75e22 beyond §14.

## Client

No critical or high-severity findings.

8. **MEDIUM: Moving Climbable Models keep stale cached bounds (a regression the plan's §14 does not list).**
   - **Where:** `ClimbableIndex.lua:~226-227`. `Dynamic` is set only by the attribute or by an unanchored BasePart guide.
   - **Also:** `:~258-261` marks a Model dirty only on DescendantAdded/Removing, and `:~357-364` makes `Bounds()` return the cached box for Models.
   - **Problem:** before the refactor, `GetBoundingBox()` ran live on every query.
   - **Scenario:** a tagged Model is moved by PivotTo or a tween (an elevator or platform), or it is an unanchored welded crate. W/S ledge transfers then silently fail, and `get_guide_top`'s ray can start below the real top.
   - **Fix:** store `GetPivot()` per Model entry and re-measure when it changes. Also treat a Model that contains any unanchored BasePart as dynamic (check on refresh and on DescendantAdded).
   - **Status: Fixed (2b392b7).** The finding was confirmed. Each static Model entry now stores its pivot plus one reference part (PrimaryPart or first BasePart) and that part's CFrame. `_flush` (every `QueryBox`) and `Bounds` re-measure the Model when either value has changed, so a Model with no PrimaryPart whose parts are tweened is caught as well. `_refresh` (which also runs on DescendantAdded/Removing) scans the Model and treats it as dynamic if any BasePart is unanchored. Specs are in `ClimbableIndex.spec.lua`: PivotTo, parts moved directly, and a Model with an unanchored part. Plan §14.15.
9. **LOW: Replacing the Animator mid-attack leaves the attack lifecycle open.**
   - **Where:** `AnimationController/init.lua:~310-323` (`_set_animator` stops, then destroys, the cached tracks) and `CombatController/AttackLifecycle.lua:~405-417`.
   - **Problem:** destroying the track disconnects the attack's Ended connection before the deferred Ended runs. So `_finish_attack` never runs: AttackTrove and AttackLease stay held, the hitbox stays active, and HitStop is never sent until the next attack or Reset.
   - **Fix:** fire a CacheReset (or similar) signal from AnimationController and have CombatController run `clear_attack_lifecycle` and `release_lease`. Alternatively, add a track `Destroying` handler in the attack trove.
   - **Status: Fixed (2b392b7).** The finding was confirmed. `_set_animator` fires `AnimationController.CacheReset` after replacing an existing cache; it does not fire for the first Animator. `CombatController` handles it by running `_finish_attack` for the in-flight attack, which sends HitStop, stops the hitbox, removes AttackTrove, releases AttackLease and resolves a buffered hold as a normal end would. `CacheReset` is required on `AnimationLike`. Specs: `AnimationController.spec.lua` (it fires only on replacement) and `CombatController.spec.lua` ("finishes the attack when the Animator is replaced mid-swing"). Plan §14.16.
10. **LOW (already present before the refactor): Sprint is ignored for one Shift press after a focus loss.**
    - **Where:** `PC.lua:~396-406` and `InputController.lua:~266-277`.
    - **Problem:** `_release_all` clears Sprint, but `PCInput.SprintActive` stays true. The next Shift press returns early.
    - **Fix:** add an optional `adapter:ReleaseAll()` called on focus release, and have PC reset `SprintActive` there.
    - **Status: Fixed (2b392b7).** The finding was confirmed. InputController keeps its adapters and, in `_release_all`, calls `ReleaseAll` on each adapter that defines one. `PCInput.ReleaseAll` clears `SprintActive` without reporting. The method is optional, so existing adapters and fakes keep working. Specs are in `InputController.spec.lua`: "begins sprint on the first Left Shift press after a focus loss" and "still accepts adapters without ReleaseAll on focus loss". Plan §14.17.

Note (already in §16; not a bug): `_position_hanging(0)` on input snaps leaves Y and facing unsmoothed for one frame.

**Checked and found sound:**
- respawn, leave and teardown order;
- every CharacterState lease release path;
- HumanoidOverrides stacks;
- parkour parity with ee75e22 (hang, mantle, lower ledge, W/S transfer, corners, vault, top-hop, jump latch);
- ClimbableIndex streaming and guides removed mid-hang;
- TrackCache reuse with `IsPlaying` guards;
- the combat client (pending timeout, hold buffering, Heavy, hitbox lifetime);
- input focus loss;
- UI no-op paths and HitHighlight pooling;
- per-frame cost.
