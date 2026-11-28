# Andes Events — Viva Voce 4

## 1. Caching Strategy

### Cache Then Network with a Rolling 15-Day Offline Cache and Time-Based Eviction

The catalog is useful offline, but upcoming events are time-sensitive. The online Firestore query in `lib/features/andes_events/data/repositories/firebase_andes_events_repository.dart` requests all published documents with `Source.server`; the UI retains every valid event whose end is in the future, including events over 15 days away. There is no fixed result limit. Firestore remains authoritative.

`lib/features/andes_events/presentation/view_models/andes_events_view_model.dart` starts `_showCache` and `refresh` concurrently: SQLite is displayed as soon as it finishes while the server is contacted. Confirmed server results replace the provisional list. Failure preserves the local list; reconnect and resume request the full catalog again. Search and filters operate on the displayed list. A refresh is shared while in flight, and generation checks discard stale responses.

`lib/features/andes_events/data/repositories/sqlite_andes_events_cache.dart` opens a separate version-1 database, `parchapp-andes-catalog.sqlite`. `cached_andes_events` has `(namespace, event_id)` as its primary key and stores event fields, start/end instants and cached time as Unix milliseconds. `andes_cache_metadata` stores the last successful synchronization time. The namespace is the Firebase project ID. `read` transactionally prunes records and reads the timestamp; `replace` atomically replaces the eligible set and metadata after server confirmation. A successful empty response clears old catalog records; failure does not. The separate Saved Events database is never pruned by this cache. There is no migration of the existing Saved database; this is a new database with its own schema version.

`lib/features/andes_events/domain/repositories/andes_events_cache.dart` defines `AndesCacheWindow`: Bogotá midnight through the exclusive midnight 15 days later. Eligibility is `end > now && end > window.start && start < window.end`, including ongoing events. Pruning occurs on open, resume, when the interface becomes unavailable, and on successful replacement. This date-based eviction is more relevant than LRU because events expire by time, regardless of how recently viewed. Trade-offs: only previously fetched near-term data is available offline, snapshots may be stale, and new far-future events do not enter the cache until another successful refresh. Bogotá is calculated with its currently observed UTC−05:00 offset; a future time-zone rule change would require an update or a time-zone database.

## 2. Eventual Connectivity Strategy

Browsing: `AndesEventsViewModel.load`, `_showCache`, `_refresh`, `_onConnection`, and `onResume` coordinate cache and authoritative refresh. ConnectivityService reports network interfaces as hints, never as proof of Firestore reachability. The Firestore query uses `Source.server` and a 15-second timeout. Server failures fall back to SQLite, with distinct permission/authentication messages; Wi-Fi without a working service is shown as a backend failure. Local search, filters, details and bookmarks work without network. Saved snapshots use their own per-project, per-user SQLite storage and survive catalog pruning.

Remote Add to Schedule uses the SQLite outbox and server-only Firestore transaction described in “Eventual Connectivity — Offline Schedule Operations” below. A pending operation is not marked as added before confirmation. Saved Events are scoped to project and UID, and the public catalog cache is scoped to the Firebase project.

Cache timestamps represent a confirmed server fetch followed by a successful local transaction, not a cache read. If SQLite fails, the live list remains usable but offline fallback may not be available. Web SQLite is not implemented. Firestore rules are unchanged.

## 3. Usability Antipattern

### POF — Poor Offline Feedback / Lack of Connectivity Awareness

**POF (Problem):** Users could mistake locally stored data for a complete, current catalog.

**Solution:** `lib/features/andes_events/presentation/views/andes_events_view.dart` renders a compact offline, reconnecting, access-error or backend-error banner above the controls. It labels the cache's 15-day limit, displays the real last successful cache synchronization where available, and offers retry. The confirmed online catalog hides the banner. Saved snapshots separately warn they may be out of date.

**Code:** `_statusBanner` and `_content` render state; `AndesEventsViewModel` tracks `serverConfirmed`, `networkAvailable`, `refreshing`, `reconnecting`, `lastSync` and errors; the SQLite cache persists data; `ConnectivityService` supplies interface hints and Firestore confirms reachability.

**Benefit:** Better Visibility of System Status and clearer expectations about completeness, freshness and whether a remote action is confirmed.

## 4. Demonstration Plan

1. Populate the published Firestore catalog with valid upcoming events inside and beyond 15 days, then open Andes Events online.
2. Verify “All upcoming events” includes the distant event. Inspect `cached_andes_events` in the local SQLite file: only overlapping near-term entries should be present.
3. Disconnect the simulator. Show “You're offline”, the cache heading, the actual last sync time, and that only cached near-term events remain.
4. Search and filter, open event details and toggle a Saved bookmark offline. Try Add to Schedule and show the connection requirement.
5. Reconnect. Show “Connection restored” during the request, then the complete catalog and absence of the banner after server confirmation. Add an event and wait for “Added”.

**Oral explanation:** “The app displays its local near-term catalog immediately and then asks Firestore for the complete upcoming catalog. A successful server response replaces what the user sees and atomically updates only the next fifteen Bogotá calendar days in SQLite. Offline, the banner explains that the list is limited and might be stale. Bookmarks are stored separately, and Schedule writes are only reported as added after Firestore confirms them.”

## App-wide Eventual Connectivity Audit

This is an initial source audit, not a claim of complete coverage. A full per-action device and failure-mode test remains necessary.

| Functionality | Online | Offline / reconnect | Evidence and gaps |
|---|---|---|---|
| Andes Events | Full confirmed Firestore catalog; batch Schedule writes | Rolling catalog cache, local filters and Saved; refresh on reconnect; no custom write queue | Files above. Mid-write disconnection can leave SDK acknowledgement pending; no durable pending-status UI. |
| Schedule and friends | Firestore private and friend availability | Existing cache/freshness and refresh messaging; no saved data state | `lib/features/schedule/presentation/view_models/schedule_view_model.dart`, `lib/features/schedule/data/repositories/firebase_schedule_repository.dart`. Verify every friend-query failure and cache completeness on device. |
| Google Calendar import | Authorization and remote import | Explicitly blocked offline; user retries | `schedule_view_model.dart` (`importGoogleCalendar`); no background import queue. |
| Groups | Firestore and callable reads | Uses cached data with freshness, or reports missing cache | `lib/features/groups/data/data_sources/firestore_groups_data_source.dart`, `lib/features/groups/presentation/view_models/active_groups_view_model.dart`. Audit all group mutations and reconnect handling individually. |
| Activities | Firebase/callable operations | Selected reads use offline data; nonqueued mutations require connection | `lib/features/activities/data/data_sources/firebase_activity_data_source.dart`, `lib/core/data/offline_mobile_api.dart`. Audit each creation/edit/cancellation flow and server-failure classification. |
| Invitation responses and alerts read | Callable commands | `OfflineMobileApi` queues only `respondToActivityInvitation` and `markAlertsRead`, with account scope and replay logic | `lib/core/data/offline_mobile_api.dart`. Verify conflict and permanent-error UX across every entry point. |
| Profile and photos | Remote profile operations | Some cached callable reads; photo changes explicitly require connection | `lib/features/profile/presentation/view_models/profile_view_model.dart`, `lib/core/data/offline_mobile_api.dart`. Audit all presence/preferences writes and freshness. |
| Authentication | Firebase sign-in/session restore | Availability depends on restored session and provider; explicit online sign-in required | `lib/core/data/restore_auth_session.dart`, `lib/features/auth/`. Audit expired credentials and network-loss feedback across each provider. |
| Location, maps, external sharing and weather | Platform or remote services | Varies by plugin and saved data; no universal queue | `lib/features/schedule/data/repositories/geolocator_location_repository.dart`, `lib/features/activities/presentation/widgets/activity_location_preview.dart`, `lib/features/groups/`. Test permissions, absent service and reconnect individually. |


## Concurrency Strategy — Concurrent I/O and Race Condition Prevention

**Problem:** Sequential SQLite and Firestore requests delayed authoritative results, while concurrent screen and connectivity triggers could produce stale state or conflicting cache writes.

**Solution:** `lib/features/andes_events/presentation/view_models/andes_events_view_model.dart` starts `refresh()` and `_showCache()` independently in `load()` and `onResume()`. Each can update the UI on completion; the wait at the end does not delay either update. Generation checks and `serverConfirmed` prevent an old response or delayed cache read from replacing confirmed data. A static serialized write tail and monotonic tickets coordinate `cache.replace()` across view-model instances. `SqliteAndesEventsCache.coordinationKey` identifies the shared database and project. Within one screen, `refresh()` is single-flight: simultaneous manual and automatic triggers reuse the current operation. Once it finishes or fails, a later retry starts a new request. An invalidated request after reconnect or account change is followed by another request.

```dart
final remote = networkAvailable != false ? refresh() : Future<void>.value();
final local = _showCache();
await Future.wait([local, remote]); // UI updates occur inside each operation.
```

**Why it is concurrency:** Both I/O operations can be outstanding independently; Dart application code still runs on the main isolate. This is asynchronous I/O concurrency, not CPU parallelism. No isolate or worker is introduced. The small catalog does not justify isolate startup and message-transfer overhead.

**Evidence:** `test/features/andes_events/concurrency_test.dart` uses controlled completers for both completion orders, single-flight refresh, retry, disposal and serialization across screen instances. `test/features/andes_events/concurrency_performance_test.dart` runs a controlled comparison with 80 ms local and 160 ms network delays. One measured run reported: sequential local 82 ms, remote 164 ms, first display 84 ms, authoritative result 250 ms; concurrent local 82 ms, remote 162 ms, first display 87 ms, authoritative result 168 ms. Three simultaneous triggers produced one network request, avoiding two duplicates. These are synthetic measurements from the test environment, not production Firebase or device benchmarks; scheduling and device results will vary.

**Trade-offs:** Cache-first rendering remains provisional until Firestore confirms the complete catalog. A shared write queue serializes cache reconciliations, favoring correctness over parallel SQLite writes. Account/connectivity generation checks discard obsolete results; they do not cancel an already-started Firestore operation. Manual refresh during an active equivalent operation shares it instead of forcing another request.

## Eventual Connectivity — Offline Schedule Operations

**Problem:** Adding an event needs two Firestore writes and can be interrupted by network loss. The user's intention must survive a restart without presenting an unconfirmed write as successful.

**Solution:** `lib/features/andes_events/data/repositories/sqlite_schedule_outbox.dart` stores a persistent outbox in the separate version-1 `parchapp-schedule-outbox.sqlite` database. `pending_schedule_operations` uses the composite key `(user_id, event_id, operation_type)`, a minimal event JSON snapshot, state, timestamps, retry count and last error. User IDs include the Firebase project. It stores no credentials. There is no migration of the separate Saved or catalog databases. Pending operations do not depend on catalog eviction.

`lib/features/andes_events/domain/services/schedule_outbox.dart` persists the intention before notifying the UI; it uses `pending`, `syncing`, `confirmed` and `failed` states. Restarted `syncing` entries are returned to `pending`. Synchronization is single-flight and processes entries serially, always under the original authenticated user. Temporary Firestore errors return to pending; permission errors and invalid or changed events fail and do not automatically loop. A user can explicitly retry. When time or location changed, retrying from a current server-backed event card is treated as accepting the displayed event snapshot; retry replaces the failed payload in one local update.

`lib/features/andes_events/data/repositories/firebase_schedule_intent_sender.dart` uses a Firestore **transaction**, which requires connectivity, rather than enqueueing a batch in the Firestore SDK's offline write queue. It verifies the authenticated account, reads the deterministic existing slot first for safe crash recovery, and otherwise re-reads the authoritative event before writing. Missing, inaccessible, unpublished, invalid, expired or materially changed events are not newly added. Private and privacy-safe availability slots are written together. Existing matching slots are treated as already confirmed, with availability repaired if necessary. The client only changes to confirmed after the transaction returns successfully. Catalog read permissions do not distinguish an unpublished or missing document from a permission denial in all cases, so the error says access was denied or the event is no longer published.

`lib/app/dependency_injection/firebase_dependencies.dart` starts synchronization on authentication changes, app resume and connectivity hints; Andes Events also requests it on open and confirmed catalog refresh. An interface signal is not proof of server connectivity: the transaction is the confirmation. `lib/features/andes_events/presentation/views/andes_events_view.dart` shows Pending sync, Syncing, or a failure explanation; it does not claim Added before confirmation. The existing Remove from Schedule action still requires network. There is no separate background worker when the application process is terminated: synchronization resumes when the app runs again. Firebase transactions can remain in progress until the SDK returns; no timeout is treated as proof that a write failed.

**Demonstration:** Open Andes Events online to cache upcoming events, disconnect, add an event and observe Pending sync, close and reopen, then reconnect and observe Syncing and confirmation. Inspect `schedules/{uid}/slots/{id}` and `availability/{uid}/slots/{id}` for one matching private and busy entry. This demonstration requires a real Firebase/emulator run; unit tests do not by themselves verify deployed rules or device connectivity transitions.
