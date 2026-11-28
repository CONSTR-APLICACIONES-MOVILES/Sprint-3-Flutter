import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../domain/entities/andes_event.dart';
import '../../domain/repositories/andes_events_repository.dart';
import '../../domain/repositories/andes_events_cache.dart';
import '../../domain/repositories/saved_andes_events_repository.dart';
import '../../domain/services/schedule_outbox.dart';

class AndesEventsViewModel extends ChangeNotifier {
  // All screen instances share the write queue and freshness tokens.
  static Future<void> _cacheWriteTail = Future.value();
  static int _nextTicket = 0;
  static final Map<Object, int> _latestAccepted = {};
  final AndesEventsRepository repository;
  final SavedAndesEventsRepository? savedRepository;
  final AndesEventsCache? cache;
  final ScheduleOutbox? outbox;
  final DateTime Function() clock;
  StreamSubscription<bool>? _connectionSubscription;
  bool? networkAvailable;
  bool serverConfirmed = false;
  bool refreshing = false;
  bool reconnecting = false;
  bool cacheFailure = false;
  DateTime? lastSync;
  Future<void>? _inFlight;
  int _generation = 0;
  StreamSubscription<String?>? _accountSubscription;
  String? _userId;
  int _accountGeneration = 0;
  bool savedLoading = false;
  String? savedError;
  bool showSaved = false;
  List<AndesEvent> savedEvents = [];
  final Set<String> saving = {};

  AndesEventsViewModel(this.repository,
      {this.savedRepository, String? userId, Stream<String?>? accountChanges,
      this.cache, this.outbox, DateTime Function()? clock, Stream<bool>? connectivityChanges}) : clock = clock ?? DateTime.now {
    outbox?.addListener(_outboxChanged);
    _connectionSubscription = connectivityChanges?.listen(_onConnection);
    _setAccount(userId);
    _accountSubscription = accountChanges?.listen(_setAccount);
  }
  void _setAccount(String? userId) {
    if (_userId == userId && _accountGeneration > 0) return;
    _userId = userId;
    _accountGeneration++;
    _generation++;
    if (_accountGeneration > 1) {
      events = [];
      added = {};
      serverConfirmed = false;
      if (userId != null) {
        final pending = _inFlight;
        if (pending == null) { Future.microtask(load); }
        else { pending.whenComplete(() { if (!_disposed && _userId != null) load(); }); }
      }
    }
    savedEvents = [];
    savedLoading = false;
    saving.clear();
    savedError = userId == null ? 'Sign in to access saved events.' : null;
    added = {};
    notifyListeners();
    if (userId != null && savedRepository != null) refreshSaved();
    if (outbox != null) { unawaited(outbox!.refresh().catchError((Object _) {})); }
  }

  Future<void> refreshSaved() async {
    final uid = _userId;
    final generation = _accountGeneration;
    if (uid == null || savedRepository == null) return;
    savedLoading = true;
    savedError = null;
    notifyListeners();
    try {
      final result = await savedRepository!.getSaved(uid);
      if (generation == _accountGeneration) savedEvents = result;
    } catch (_) {
      if (generation == _accountGeneration)
        savedError = 'Could not load saved events. Please try again.';
    } finally {
      if (generation == _accountGeneration) {
        savedLoading = false;
        notifyListeners();
      }
    }
  }

  bool isSaved(String id) => savedEvents.any((event) => event.id == id);
  void selectSaved(bool value) {
    showSaved = value;
    notifyListeners();
  }

  Future<String?> toggleSaved(AndesEvent event) async {
    final uid = _userId;
    final generation = _accountGeneration;
    if (uid == null) return 'Sign in to save events.';
    if (savedRepository == null)
      return 'Saved events are not available on this device.';
    if (saving.contains(event.id)) return null;
    saving.add(event.id);
    notifyListeners();
    try {
      if (isSaved(event.id)) {
        await savedRepository!.remove(uid, event.id);
      } else {
        await savedRepository!.save(uid, event);
      }
      if (generation == _accountGeneration) {
        await refreshSaved();
        if (savedError != null) return savedError;
      }
      return null;
    } catch (_) {
      return 'Could not update saved events. Please try again.';
    } finally {
      if (generation == _accountGeneration) {
        saving.remove(event.id);
        notifyListeners();
      }
    }
  }

  void _outboxChanged() {
    if (outbox == null || _userId == null) return;
    for (final op in outbox!.operations.values) {
      if (op.userId != _userId) continue;
      if (op.status == 'confirmed' && added.add(op.event.id)) {
        _scheduleMutationVersion++;
        changed = true;
      }
    }
    notifyListeners();
  }
  List<ScheduleIntent> get failedOperations => outbox?.operations.values
      .where((op) => op.userId == _userId && op.status == 'failed').toList() ?? [];
  ScheduleIntent? operation(String eventId) {
    final op = outbox?.operations[eventId];
    return op?.userId == _userId ? op : null;
  }
  Future<String?> retryOperation(AndesEvent event) async {
    if (outbox == null) return 'Sync is unavailable.';
    try {
      // A failed request may refer to outdated event data. The current card
      // is a fresh, explicit user choice and replaces the failed snapshot.
      await outbox!.retry(event.id, updatedEvent: event);
      return null;
    } catch (_) { return 'Could not save the operation. Please try again.'; }
  }

  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    _accountSubscription?.cancel();
    _connectionSubscription?.cancel();
    outbox?.removeListener(_outboxChanged);
    _generation++;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool loading = true;
  String? error;
  int invalidCount = 0;
  List<AndesEvent> events = [];
  Set<String> added = {};
  final Set<String> adding = {};
  int _scheduleMutationVersion = 0;
  String query = '', category = 'all';
  bool changed = false;
  List<AndesEvent> get filtered =>
      (showSaved ? savedEvents : events).where((e) {
        final q = query.trim().toLowerCase();
        return (category == 'all' || e.category == category) &&
            [e.title, e.description, e.location]
                .any((s) => s.toLowerCase().contains(q));
      }).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  void search(String value) {
    query = value;
    notifyListeners();
  }

  void filter(String value) {
    category = value;
    notifyListeners();
  }

  void _onConnection(bool available) {
    if (_disposed) return;
    final previous = networkAvailable;
    networkAvailable = available;
    if (!available) {
      _generation++;
      refreshing = false;
      serverConfirmed = false;
      events = [];
      reconnecting = false;
      _showCache();
    } else if (previous == false) {
      reconnecting = true;
      final pending = _inFlight;
      if (pending == null) { refresh(); } else {
        pending.whenComplete(() { if (!_disposed && networkAvailable == true && !serverConfirmed) refresh(); });
      }
    }
    notifyListeners();
  }

  Future<void> _showCache() async {
    final generation = _generation;
    if (cache == null) { events = []; loading = false; notifyListeners(); return; }
    try {
      final snapshot = await cache!.read(AndesCacheWindow(clock()));
      if (_disposed || generation != _generation || serverConfirmed) return;
      events = snapshot.events;
      lastSync = snapshot.lastSync;
      cacheFailure = false;
    } catch (_) { if (!_disposed && generation == _generation && !serverConfirmed) { events = []; cacheFailure = true; } }
    if (!_disposed && generation == _generation && !serverConfirmed) { loading = false; notifyListeners(); }
  }

  Future<void> load() async {
    if (_disposed) return;
    if (outbox != null) { unawaited(outbox!.refresh().catchError((Object _) {})); if (networkAvailable != false) unawaited(outbox!.sync().catchError((Object _) {})); }
    final remote = networkAvailable != false ? refresh() : Future<void>.value();
    final local = _showCache();
    await Future.wait([local, remote]);
  }

  Future<void> onResume() async {
    if (_disposed) return;
    final remote = networkAvailable != false ? refresh() : Future<void>.value();
    // Always prune on resume; never replace a confirmed server list.
    final local = _showCache();
    await Future.wait([local, remote]);
  }

  Future<void> refresh() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final operation = _refresh();
    _inFlight = operation;
    return operation.whenComplete(() { if (identical(_inFlight, operation)) _inFlight = null; });
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    final ticket = ++_nextTicket;
    refreshing = true;
    error = null;
    notifyListeners();
    try {
      final result = await repository.load().timeout(const Duration(seconds: 15));
      if (_disposed || generation != _generation || networkAvailable == false) return;
      final now = clock();
      events = result.events.where((e) => e.end.isAfter(now)).toList()..sort((a, b) => a.start.compareTo(b.start));
      invalidCount = result.invalidCount;
      serverConfirmed = true;
      if (outbox != null) unawaited(outbox!.sync().catchError((Object _) {}));
      loading = false;
      reconnecting = false;
      error = null;
      notifyListeners();
      if (cache != null) {
        final target = cache!;
        final key = target is AndesCacheIdentity ? (target as AndesCacheIdentity).coordinationKey : target;
        final prior = _latestAccepted[key];
        if (prior == null || ticket > prior) _latestAccepted[key] = ticket;
        final snapshot = List<AndesEvent>.of(events);
        final write = _cacheWriteTail.then((_) async {
          if (_disposed || generation != _generation || _latestAccepted[key] != ticket) return;
          await target.replace(snapshot, AndesCacheWindow(now), now);
          if (!_disposed && generation == _generation) { lastSync = now; cacheFailure = false; }
        });
        _cacheWriteTail = write.catchError((Object _) {});
        try { await write; } catch (_) { if (!_disposed && generation == _generation) cacheFailure = true; }
      }
      try {
        final mutationVersion = _scheduleMutationVersion;
        final ids = await repository.addedIds().timeout(const Duration(seconds: 15));
        if (generation == _generation && !_disposed && adding.isEmpty && mutationVersion == _scheduleMutationVersion) added = ids;
      } catch (_) { /* Catalog availability does not depend on schedule reads. */ }
    } catch (e) {
      if (!_disposed && generation == _generation) {
        serverConfirmed = false;
        reconnecting = false;
        error = message(e);
        await _showCache();
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        refreshing = false;
        notifyListeners();
      }
    }
  }

  Future<String?> add(AndesEvent event) async {
    if (adding.contains(event.id) || added.contains(event.id)) return null;
    if (outbox != null) {
      try {
        await outbox!.enqueue(event);
        if (serverConfirmed && networkAvailable != false) {
          unawaited(outbox!.sync().catchError((Object _) {}));
        }
        return null;
      } catch (e) { return e is StateError ? e.message : 'Could not save the operation. Please try again.'; }
    }
    if (!serverConfirmed || networkAvailable == false) return 'An internet connection is required to add an event to Schedule.';
    final generation = _accountGeneration;
    adding.add(event.id);
    _scheduleMutationVersion++;
    notifyListeners();
    try {
      await repository.add(event);
      if (generation != _accountGeneration || _disposed) return null;
      added.add(event.id);
      changed = true;
      return null;
    } catch (e) {
      return message(e);
    } finally {
      adding.remove(event.id);
      notifyListeners();
    }
  }

  Future<String?> remove(AndesEvent event) async {
    if (!serverConfirmed || networkAvailable == false) {
      return 'An internet connection is required to remove an event from Schedule.';
    }
    if (adding.contains(event.id) || !added.contains(event.id)) return null;
    final generation = _accountGeneration;
    adding.add(event.id);
    _scheduleMutationVersion++;
    notifyListeners();
    try {
      await repository.remove(event);
      if (generation != _accountGeneration || _disposed) return null;
      added.remove(event.id);
      await outbox?.forget(event.id);
      changed = true;
      return null;
    } catch (e) {
      return message(e);
    } finally {
      adding.remove(event.id);
      notifyListeners();
    }
  }

  static String message(Object e) {
    if (e is TimeoutException) return 'The event service timed out. Please try again.';
    if (e is FirebaseException) {
      if (e.code == 'unauthenticated') return 'Please sign in again to access events.';
      if (e.code == 'permission-denied')
        return 'Access denied. Please check your account permissions.';
      if (e.code == 'unavailable' || e.code == 'deadline-exceeded')
        return 'Connection unavailable. Please try again.';
    }
    if (e is StateError) return e.message;
    return 'Could not load or save events. Please try again.';
  }
}
