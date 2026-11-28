import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parchapp/features/andes_events/data/repositories/sqlite_andes_events_cache.dart';
import 'package:parchapp/features/andes_events/domain/entities/andes_event.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_cache.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_repository.dart';
import 'package:parchapp/features/andes_events/presentation/view_models/andes_events_view_model.dart';

AndesEvent event(String id, DateTime start, DateTime end) => AndesEvent(id: id, title: 'Event $id', description: 'Details', category: 'academic', location: 'Campus', start: start, end: end);
class Remote implements AndesEventsRepository {
  Completer<AndesEventsResult> current = Completer();
  int calls = 0;
  @override Future<AndesEventsResult> load() { calls++; return current.future; }
  @override Future<Set<String>> addedIds() async => {};
  @override Future<void> remove(AndesEvent event) async {}
  @override Future<void> add(AndesEvent event) async {}
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  final now = DateTime.utc(2026, 11, 22, 15);
  late Directory dir; late SqliteAndesEventsCache cache;
  setUp(() async { dir = await Directory.systemTemp.createTemp('andes-cache-'); cache = SqliteAndesEventsCache(namespace: 'project', path: '${dir.path}/cache.sqlite', factory: databaseFactoryFfi); });
  tearDown(() async { await cache.close(); await dir.delete(recursive: true); });
  test('Bogota window, pruning, persistence and atomic empty reconciliation', () async {
    final window = AndesCacheWindow(now);
    expect(window.start, DateTime.utc(2026, 11, 22, 5));
    expect(window.end, DateTime.utc(2026, 12, 7, 5));
    final ongoing = event('ongoing', now.subtract(const Duration(days: 2)), now.add(const Duration(hours: 1)));
    final near = event('near', window.end.subtract(const Duration(minutes: 1)), window.end.add(const Duration(hours: 1)));
    final far = event('far', window.end, window.end.add(const Duration(hours: 1)));
    final expired = event('expired', now.subtract(const Duration(hours: 2)), now);
    await cache.replace([ongoing, near, near, far, expired], window, now);
    await cache.close(); cache = SqliteAndesEventsCache(namespace: 'project', path: '${dir.path}/cache.sqlite', factory: databaseFactoryFfi);
    var snapshot = await cache.read(window);
    expect(snapshot.events.map((e) => e.id), ['ongoing', 'near']); expect(snapshot.lastSync?.toUtc(), now);
    snapshot = await cache.read(AndesCacheWindow(now.add(const Duration(hours: 2))));
    expect(snapshot.events.map((e) => e.id), ['near']);
    await cache.replace([], window, now.add(const Duration(hours: 1)));
    expect((await cache.read(window)).events, isEmpty);
  });
  test('cache appears first, complete server catalog replaces it and failures preserve it', () async {
    final near = event('near', now.add(const Duration(days: 1)), now.add(const Duration(days: 1, hours: 1)));
    final far = event('far', now.add(const Duration(days: 60)), now.add(const Duration(days: 60, hours: 1)));
    await cache.replace([near], AndesCacheWindow(now), now);
    final remote = Remote(); final vm = AndesEventsViewModel(remote, cache: cache, clock: () => now);
    final future = vm.load();
    while (vm.events.isEmpty) { await Future<void>.delayed(const Duration(milliseconds: 5)); }
    expect(vm.events.map((e) => e.id), ['near']); expect(vm.serverConfirmed, false);
    vm.search('event'); vm.filter('academic');
    remote.current.complete(AndesEventsResult([far, near], 0)); await future;
    expect(vm.events.map((e) => e.id), ['near', 'far']); expect(vm.serverConfirmed, true);
    expect((await cache.read(AndesCacheWindow(now))).events.map((e) => e.id), ['near']);
    remote.current = Completer(); final retry = vm.refresh();
    remote.current.completeError(FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied')); await retry;
    expect(vm.events.map((e) => e.id), ['near']); expect(vm.error, contains('Access denied'));
    expect(vm.query, 'event'); expect(vm.category, 'academic'); vm.dispose();
  });
  test('reconnection restores server catalog and concurrent requests share one fetch', () async {
    final changes = StreamController<bool>(); final remote = Remote();
    final vm = AndesEventsViewModel(remote, cache: cache, clock: () => now, connectivityChanges: changes.stream);
    changes.add(false); await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(vm.networkAvailable, false);
    changes.add(true); await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(vm.reconnecting, true); final another = vm.refresh(); expect(remote.calls, 1);
    remote.current.complete(AndesEventsResult([event('far', now.add(const Duration(days: 40)), now.add(const Duration(days: 40, hours: 1)))], 0));
    await another; expect(vm.serverConfirmed, true); expect(vm.events.single.id, 'far');
    vm.dispose(); await changes.close();
  });
}
