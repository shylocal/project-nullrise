# Adversarial review findings (post-refactor, ee75e22..b095845)

These came out of the read-only adversarial review. The Finish step verifies each finding, fixes the real ones with regression specs, and records the outcome here.

## Server and shared

No critical or high-severity findings.

1. **MEDIUM: A Heavy (Charge) move skips its own recovery, which allows a 45–60 damage burst.**
   - **Where:** `CombatService.lua:~515` sets `NextAttackAt = now + MinDuration` at move start, and nothing changes it on release (HitStart, `:~594/~611`). `MoveKinds.lua:~204-217` keeps the HitStart window open until MaxHoldTime (10s), and the server never checks `Hold.HoldTime`.
   - **Scenario (Katana):** `Attack(Heavy)` at t=0 sets NextAttackAt to 0.6. HitStart and Hit at 0.55 deal 30. `Attack(Heavy)` at 0.56 passes (0.56 + 0.1 tolerance ≥ 0.6), and HitStart and Hit at 0.61 deal another 30. That is 60 damage within about 50ms. This is not a regression; ee75e22 behaved the same.
   - **Fix:** for `Kind == "Charge"`, on HitStart/activation set `NextAttackAt = max(NextAttackAt, release + (MinDuration - HitStartAt))`. Optionally reject a HitStart before `StartedAt + Hold.HoldTime - tolerance`.
   - **Status: Fixed (8db89af), with a different fix.** The finding was confirmed. The suggested fix would reject legitimate play. The client's cooldown (`AttackReadyAt = start + Cooldown`) is anchored at the move's start, so after a long hold the client sends a Light right after the release. For example, Katana Heavy held for 0.3s: the suggested NextAttackAt is 0.3 + 0.45 = 0.75, and a Light at the 0.6 client cooldown (0.7 with tolerance) would be rejected. The optional HitStart check is a no-op, because HoldTime elapses before the Charge request is sent. What a legitimate client cannot do is start a second Hold move without a fresh press after the release (`primary_began` ignores presses while charging) held for HoldTime, and then reach its marker. So `MoveKinds.Charge.released_at` records the release of a charge whose HitStart arrived past its marker plus tolerance (`State.ChargeReleasedAt`). The next Hold-bound move's `HitStartOpensAt` is raised to `release + HoldTime + HitStartAt - tolerance`, and an earlier HitStart is armed as usual. A release before the marker is not recorded, because its HitStart arrives at the marker and MinDuration already covers it. The reviewed burst goes from about 50ms to at least 0.2s between the two Heavy hits (legitimate play: 0.3s). Lights after a release are unchanged. Specs: `CombatService.spec.lua` ("delays a second Heavy's hit…", "does not delay a Light right after a long Heavy hold", "does not delay a Heavy from a fresh hold…", "records no release…", "forgets the last charge release…") and `MoveKinds.spec.lua` ("knows a charge's release…"). Plan §14.18.
2. **MEDIUM: Load-time sanitising permanently deletes persisted items.**
   - **Where:** `Schema.lua:~403, ~440-451`, via `PlayerDataService.lua:~222`.
   - **Problem:** slots with an ItemId unknown to *this build*, or a key above *this build's* MaxSlots, are deleted from `Profile.Data`, and ProfileStore saves the deletion.
   - **Scenario:** a rolling update or a rollback can wipe newly shipped items.
   - **Fix:** never mutate persisted data for "unknown to this build". Filter those slots at runtime (`build_entries` / `weapon_id_of`) and keep them in the profile, or move them to `Inventory.Orphaned`. Drop only structurally corrupt records.
   - **Status: Fixed (5d5c918; 6d5a1be removed unrelated client files that were swept into that commit).** The finding was confirmed. `Schema.sanitize(data)` no longer takes `max_slots`. It drops only structurally corrupt slots: a key that is not an unpadded positive integer, a malformed record (missing Uid or ItemId, or Data not a table), or a duplicate Uid. Records with an ItemId this build doesn't know, or a slot above MaxSlots, stay in the profile as saved. InventoryService filters them at runtime: `known()` keeps them out of the replicated entries and out of `GetSelected`, they equip the default weapon, and their slot still counts as occupied, so `Grant` never overwrites it. Specs: `DataSchema.spec.lua` ("drops corrupt slot keys…", "never drops records only because this build does not recognise them"), `PlayerDataService.spec.lua` ("drops corrupt slots, keeps unrecognised ones…", including the saved copy) and `InventoryService.spec.lua` ("keeps records this build does not recognise, without exposing them"). Plan §14.19.
3. **LOW: A failed migration still writes to saved data.**
   - **Where:** `PlayerDataService.lua:~211-218`. `profile:Reconcile()` runs before `Schema.migrate` and mutates the data in place.
   - **Problem:** a newer-version profile gets stray V1 keys and is then saved by EndSession. A profile whose Version is missing or corrupt gets Version=1 and is then sanitised.
   - **Fix:** validate or migrate a copy first, and Reconcile only after a successful migrate.
   - **Status: Fixed (b031d3e).** The finding was confirmed. `Schema.run_migrations` runs on `Freeze.clone_deep(profile.Data)`, which covers the version gate and the migration chain. A newer profile, one with a missing or invalid Version, or one whose migration fails is released untouched. Otherwise the upgraded copy becomes `profile.Data`, and only then do `AddUserId` and `Reconcile` run. The shape is then checked by the new `Schema.validate`; `Schema.migrate` is now `run_migrations` followed by `validate`. Specs in `PlayerDataService.spec.lua`: "never writes to a newer profile it refuses" and "refuses a profile without a valid Version without giving it one". Plan §14.19.
4. **LOW: An error after the profile loads leaks the profile session.**
   - **Where:** `PlayerDataService.lua:~211-247` and `PlayerService.lua:~243`.
   - **Problem:** if anything throws between StartSessionAsync and session:Set, the component never completes, so OnPlayerRemoving never calls EndSession. The profile stays locked and autosaved, the player has no inventory, and a rejoin to the same server is kicked.
   - **Fix:** wrap the post-load block in a pcall that calls `profile:EndSession()` and then `_fail`.
   - **Status: Fixed (b031d3e).** The finding was confirmed. Everything after the copy-migrate is in `PlayerDataService._open`, which runs inside a pcall. `_open` sets the component state before it connects the steal listener. On an error, OnPlayerAdded either clears that state, which disconnects the listener and then ends the session, so no false "opened on another server" kick, or ends the bare profile. It then calls `_fail`: a live server kicks, and Studio falls back to an in-memory profile. `FakeProfileStore` gained an `AfterStart(profile)` hook. Specs in `PlayerDataService.spec.lua`: "releases the profile when opening it throws", "…without a steal kick when a later step throws" and "falls back to an unsaved profile in Studio when opening throws".
5. **LOW: Client-controlled strings reach AnalyticsService.**
   - **Where:** `RemoteBudget.lua:~136`, where UnknownAction uses the raw action string as `detail`, and `Telemetry.lua:~213-216`, which sends it as `CustomField02`.
   - **Problem:** an attacker can pollute analytics custom-field cardinality and rate limits for the whole experience.
   - **Fix:** log a constant such as `"<unknown>"` for client-supplied details, and keep the raw text only in the Studio print.
   - **Status: Fixed (dd0046d).** The finding was confirmed. The UnknownAction detail is now the server's remote prefix plus `RemoteBudget.UNKNOWN`, for example `Combat.<unknown>`. RemoteBudget now requires an `is_studio` dep, and in Studio it prints the raw name, truncated to 64 characters. Other telemetry details were checked and are all server-chosen: weapon ids, budget-config action keys and constants. Specs: `RemoteBudget.spec.lua` ("never passes a client-chosen action name to analytics", which checks the AnalyticsService fields) and the updated keys in the CombatService and InventoryService specs. Plan §14.20.
6. **LOW (minor):** the `Weapon` and `CombatFx` remotes have no OnServerEvent handler, so clients firing them fill the engine queue and spam warnings into server logs. Fix: a no-op handler that counts UnknownAction.
   - **Status: Fixed (576669f).** The finding was confirmed. The new `server/network/InboundSink.lua` is composed as `WeaponInbound` (in compose/Items) and `CombatFxInbound` (in compose/Combat). It charges each inbound event to `RemoteBudget:Take(player, "<Remote>.Inbound")`, which spends global budget and counts `Network.UnknownAction.<Remote>.<unknown>`. Spec: `InboundSink.spec.lua`. Plan §14.20.
7. **LOW (minor):** `DamageService._recent` (`:~317-326`) never frees the record for an unparented, but not destroyed, non-player target. This only matters for NPCs.
   - **Status: Fixed (0d5bdeb).** The finding was confirmed. Each record also listens to `AncestryChanged` and forgets the target once it is no longer a descendant of `game`. Moving within the DataModel keeps the record. Specs in `DamageService.spec.lua`: "forgets a target's attackers when the target leaves the DataModel" and "keeps … when it moves within the DataModel".

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
