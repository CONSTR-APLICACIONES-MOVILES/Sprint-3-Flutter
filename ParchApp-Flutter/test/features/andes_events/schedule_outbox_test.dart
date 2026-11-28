import 'dart:async';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parchapp/features/andes_events/data/repositories/sqlite_schedule_outbox.dart';
import 'package:parchapp/features/andes_events/domain/entities/andes_event.dart';
import 'package:parchapp/features/andes_events/domain/services/schedule_outbox.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_repository.dart';
import 'package:parchapp/features/andes_events/presentation/view_models/andes_events_view_model.dart';

class Sender implements ScheduleIntentSender {
  int calls = 0;
  final users = <String>[];
  Completer<void>? gate;
  Object? error;
  @override Future<void> send(String userId, AndesEvent event) async {
    calls++; users.add(userId);
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
  }
}
class OfflineRemote implements AndesEventsRepository {
  @override Future<AndesEventsResult> load() async => throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
  @override Future<Set<String>> addedIds() async => {};
  @override Future<void> add(AndesEvent event) async => throw StateError('Must use outbox');
  @override Future<void> remove(AndesEvent event) async {}
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  late Directory dir; late SqliteScheduleOutbox store;
  final now = DateTime.utc(2030, 1, 1);
  final event = AndesEvent(id: 'one', title: 'Lecture', description: 'Details', category: 'academic', location: 'Campus', start: now.add(const Duration(days: 1)), end: now.add(const Duration(days: 1, hours: 1)));
  setUp(() async { dir = await Directory.systemTemp.createTemp('outbox-'); store = SqliteScheduleOutbox(path: '${dir.path}/outbox.sqlite', factory: databaseFactoryFfi); });
  tearDown(() async { await store.close(); await dir.delete(recursive: true); });
  test('pending persists across reopen, deduplicates and isolates accounts', () async {
    final sender = Sender(); final box = ScheduleOutbox(store, sender, () => 'project:a', clock: () => now);
    await box.enqueue(event); await box.enqueue(event);
    expect(box.operations['one']?.status, 'pending'); expect(sender.calls, 0);
    await store.close(); store = SqliteScheduleOutbox(path: '${dir.path}/outbox.sqlite', factory: databaseFactoryFfi);
    expect((await store.list('project:a')).single.status, 'pending');
    expect(await store.list('project:b'), isEmpty);
  });
  test('single flight waits for confirmation, recovers syncing and keeps user scope', () async {
    String uid = 'a'; final sender = Sender()..gate = Completer<void>(); final box = ScheduleOutbox(store, sender, () => uid, clock: () => now);
    await box.enqueue(event); await store.status('a', 'one', 'syncing');
    final first = box.sync();
    while (sender.calls == 0) { await Future<void>.delayed(const Duration(milliseconds: 1)); }
    expect((await store.list('a')).single.status, 'syncing');
    final second = box.sync(); expect(sender.calls, 1);
    uid = 'b'; await box.refresh(); expect(box.operations, isEmpty);
    sender.gate!.complete(); await Future.wait([first, second]);
    expect((await store.list('a')).single.status, 'confirmed'); expect(await store.list('b'), isEmpty); expect(sender.users, ['a']);
  });
  test('temporary failure stays pending, permission denied fails and user may retry', () async {
    final sender = Sender()..error = FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    final box = ScheduleOutbox(store, sender, () => 'a', clock: () => now);
    await box.enqueue(event); await box.sync(); expect(box.operations['one']?.status, 'pending');
    sender.error = FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'); await box.sync();
    expect(box.operations['one']?.status, 'failed'); expect(box.operations['one']?.error, contains('Access denied'));
    await box.sync(); expect(sender.calls, 2);
    sender.error = null; await box.retry('one'); await box.sync(); expect(box.operations['one']?.status, 'confirmed');
  });
  test('view model queues offline and restores pending before server confirmation', () async {
    final sender = Sender();
    final box = ScheduleOutbox(store, sender, () => 'a', clock: () => now);
    final vm = AndesEventsViewModel(OfflineRemote(), outbox: box, userId: 'a', clock: () => now);
    vm.networkAvailable = false;
    expect(await vm.add(event), isNull);
    expect(vm.operation('one')?.status, 'pending');
    expect(vm.added, isNot(contains('one'))); expect(sender.calls, 0);
    vm.dispose();
    final reopened = ScheduleOutbox(store, sender, () => 'a', clock: () => now);
    await reopened.refresh();
    expect(reopened.operations['one']?.status, 'pending');
    await reopened.sync(); expect(reopened.operations['one']?.status, 'confirmed');
  });

}
