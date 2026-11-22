import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import '../entities/andes_event.dart';

class ScheduleIntent {
  final String userId;
  final AndesEvent event;
  final String status;
  final String? error;
  const ScheduleIntent(this.userId, this.event, this.status, this.error);
}
abstract interface class ScheduleOutboxStore {
  Future<void> enqueue(String userId, AndesEvent event);
  Future<List<ScheduleIntent>> list(String userId);
  Future<void> status(String userId, String eventId, String status, {String? error});
  Future<void> delete(String userId, String eventId);
  Future<void> recover(String userId);
  Future<void> retryWithEvent(String userId, AndesEvent event);
}
abstract interface class ScheduleIntentSender {
  Future<void> send(String userId, AndesEvent event);
}

class ScheduleOutbox extends ChangeNotifier {
  final ScheduleOutboxStore store;
  final ScheduleIntentSender sender;
  final String? Function() currentUser;
  final DateTime Function() clock;
  Future<void>? _flight;
  String? _flightUser;
  bool _syncAgain = false;
  Map<String, ScheduleIntent> operations = {};
  String? _visibleUser;
  int _generation = 0;
  int _refreshVersion = 0;
  ScheduleOutbox(this.store, this.sender, this.currentUser, {DateTime Function()? clock}) : clock = clock ?? DateTime.now;
  Future<void> refresh() async {
    final uid = currentUser();
    if (_visibleUser != uid) { _visibleUser = uid; operations = {}; _generation++; notifyListeners(); }
    final generation = _generation;
    final version = ++_refreshVersion;
    if (uid == null) return;
    final entries = await store.list(uid);
    if (_generation == generation && version == _refreshVersion && currentUser() == uid) {
      operations = {for (final entry in entries) entry.event.id: entry};
      notifyListeners();
    }
  }
  Future<void> enqueue(AndesEvent event) async {
    final uid = currentUser();
    if (uid == null) throw StateError('Please sign in to add an event.');
    if (event.id.isEmpty || event.title.trim().isEmpty || event.description.trim().isEmpty || event.location.trim().isEmpty || !event.end.isAfter(event.start) || !event.end.isAfter(clock())) throw StateError('This event is invalid or has already ended.');
    await store.enqueue(uid, event);
    await refresh();
  }
  Future<void> forget(String eventId) async {
    final uid = currentUser();
    if (uid != null) { await store.delete(uid, eventId); await refresh(); }
  }
  Future<void> retry(String eventId, {AndesEvent? updatedEvent}) async {
    final uid = currentUser();
    if (uid == null) throw StateError('Please sign in again.');
    if (updatedEvent == null) {
      await store.status(uid, eventId, 'pending');
    } else {
      await store.retryWithEvent(uid, updatedEvent);
    }
    await refresh();
    unawaited(sync().catchError((Object _) {}));
  }
  Future<void> sync() {
    final uid = currentUser();
    if (uid == null) return refresh();
    if (_flight != null) {
      if (_flightUser == uid) { _syncAgain = true; return _flight!; }
      return _flight!.then((_) => sync());
    }
    final task = _syncUntilCurrent(uid);
    _flight = task; _flightUser = uid;
    return task.whenComplete(() { if (identical(_flight, task)) { _flight = null; _flightUser = null; } });
  }
  Future<void> _syncUntilCurrent(String uid) async {
    do {
      _syncAgain = false;
      await _sync(uid);
    } while (_syncAgain && currentUser() == uid);
  }
  Future<void> _sync(String uid) async {
    await store.recover(uid);
    await refresh();
    for (final op in await store.list(uid)) {
      if (currentUser() != uid) break;
      if (op.status != 'pending') continue;
      await store.status(uid, op.event.id, 'syncing');
      await refresh();
      try {
        if (currentUser() != uid) { await store.status(uid, op.event.id, 'pending'); break; }
        await sender.send(uid, op.event);
        await store.status(uid, op.event.id, 'confirmed');
      } catch (e) {
        final temporary = e is TimeoutException || (e is FirebaseException && ['unavailable', 'deadline-exceeded', 'cancelled', 'aborted', 'network-request-failed'].contains(e.code));
        final detail = e is StateError ? e.message : e is FirebaseException && e.code == 'permission-denied' ? 'Access denied or this event is no longer published.' : e is FirebaseException && e.code == 'unauthenticated' ? 'Please sign in again.' : temporary ? 'Waiting for a connection.' : 'Could not add this event. Please try again.';
        await store.status(uid, op.event.id, temporary ? 'pending' : 'failed', error: detail);
        if (temporary) { await refresh(); break; }
      }
      await refresh();
    }
  }
}
