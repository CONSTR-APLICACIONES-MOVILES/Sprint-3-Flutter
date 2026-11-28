import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parchapp/features/activities/data/repositories/sqlite_activity_drafts_repository.dart';
import 'package:parchapp/features/activities/domain/entities/activity_draft.dart';
import 'package:parchapp/features/activities/domain/entities/draft_comparison_cache.dart';
import 'package:parchapp/features/activities/domain/repositories/activity_drafts_repository.dart';
import 'package:parchapp/features/activities/presentation/controllers/draft_sync_coordinator.dart';

class SyncFailure implements Exception {
  final String code;
  SyncFailure(this.code);
}

class DraftCloud {
  final records = <String, Map<String, dynamic>>{};
  final receipts = <String, Map<String, dynamic>>{};
  bool loseResponse = false;
  Completer<void>? gate, started;
  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> input) async {
    if (name == 'getActivityDrafts') {
      return {'drafts': records.values.toList(), 'nextCursor': null};
    }
    started?.complete();
    started = null;
    final wait = gate;
    gate = null;
    await wait?.future;
    final key = '${input['id']}/${input['operationId']}';
    if (receipts.containsKey(key)) return receipts[key]!;
    if ((records[input['id']]?['version'] ?? 0) != input['expectedVersion']) {
      throw SyncFailure('aborted');
    }
    final result = <String, dynamic>{
      'id': input['id'],
      'version': (input['expectedVersion'] as int) + 1,
      'state': input['state'],
      'category': input['category'],
      'payload': input['payload'],
      'requestId': input['requestId'],
      'updatedAt': DateTime.now().toUtc().toIso8601String()
    };
    records[input['id'] as String] = result;
    receipts[key] = result;
    if (loseResponse) {
      loseResponse = false;
      throw SyncFailure('unavailable');
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late Database db, otherDb;
  late DraftCloud cloud;
  bool online = false;
  SqliteActivityDraftsRepository repo({bool other = false}) =>
      SqliteActivityDraftsRepository(
          open: () async => other ? otherDb : db,
          namespace: 'test/alice',
          sessionIsCurrent: () => true,
          remoteCall: cloud.call,
          canAttemptRemote: () => online);
  setUp(() async {
    online = false;
    cloud = DraftCloud();
    dir = await Directory.systemTemp.createTemp('parchapp-draft-sync-');
    db = await SqliteActivityDraftsRepository.openDatabaseForDrafts(
        factory: databaseFactoryFfi, path: '${dir.path}/one.sqlite');
    otherDb = await SqliteActivityDraftsRepository.openDatabaseForDrafts(
        factory: databaseFactoryFfi, path: '${dir.path}/two.sqlite');
  });
  tearDown(() async {
    await db.close();
    await otherDb.close();
    await dir.delete(recursive: true);
  });

  test(
      'offline queue survives restart, another device downloads and deletion propagates',
      () async {
    var first = repo();
    await first.save(const ActivityDraft(
        groupId: '', title: 'Offline plan', requestId: 'request'));
    expect((await first.load()).drafts.single.syncStatus, 'pending');
    await db.close();
    db = await SqliteActivityDraftsRepository.openDatabaseForDrafts(
        factory: databaseFactoryFfi, path: '${dir.path}/one.sqlite');
    first = repo();
    online = true;
    await first.synchronize();
    expect((await first.load()).drafts.single.syncStatus, 'synced');
    final second = repo(other: true);
    await second.synchronize();
    expect((await second.load()).drafts.single.activity.title, 'Offline plan');
    await first.delete((await first.load()).drafts.single);
    await first.synchronize();
    await second.synchronize();
    expect((await second.load()).drafts, isEmpty);
    expect(cloud.records.values.single['state'], 'deleted');
  });

  test(
      'reconnecting uploads saved drafts without an editor or manual sync action',
      () async {
    final available = ValueNotifier(false);
    final first = SqliteActivityDraftsRepository(
        open: () async => db,
        namespace: 'test/alice',
        sessionIsCurrent: () => true,
        remoteCall: cloud.call,
        canAttemptRemote: () => available.value);
    final coordinator = DraftSyncCoordinator(
        connectivity: available,
        canAttemptRemote: () => available.value,
        currentRepository: () => first,
        retryInterval: const Duration(days: 1))
      ..start();
    try {
      await first.save(const ActivityDraft(groupId: '', title: '000'));
      expect(first.isOffline, isTrue);
      expect(cloud.records, isEmpty);
      final uploaded = first.changes.asyncMap((_) => first.load()).firstWhere(
          (s) =>
              s.drafts.isNotEmpty &&
              s.drafts.every((d) => d.syncStatus == 'synced'));
      available.value = true;
      await uploaded.timeout(const Duration(seconds: 10));
      expect(cloud.records.values.single['payload']['title'], '000');
      expect(first.isOffline, isFalse);
    } finally {
      coordinator.dispose();
      available.dispose();
    }
  });

  test(
      'a temporary failure retries automatically even if the network interface stays available',
      () async {
    final available = ValueNotifier(true);
    final first = repo();
    await first
        .save(const ActivityDraft(groupId: '', title: 'Retry automatically'));
    cloud.loseResponse = true;
    online = true;
    final uploaded = first.changes.asyncMap((_) => first.load()).firstWhere(
        (s) =>
            s.drafts.isNotEmpty &&
            s.drafts.every((d) => d.syncStatus == 'synced'));
    final coordinator = DraftSyncCoordinator(
        connectivity: available,
        canAttemptRemote: () => available.value,
        currentRepository: () => first,
        retryInterval: const Duration(milliseconds: 30))
      ..start();
    try {
      await uploaded.timeout(const Duration(seconds: 10));
      expect(cloud.records, hasLength(1));
      expect(cloud.records.values.single['version'], 1);
      expect(first.isOffline, isFalse);
    } finally {
      coordinator.dispose();
      available.dispose();
      await first.synchronize();
    }
  });

  test(
      'lost cloud acknowledgement retries the same operation without duplicates',
      () async {
    final first = repo();
    await first.save(const ActivityDraft(groupId: '', title: 'Retry'));
    cloud.loseResponse = true;
    online = true;
    await first.synchronize();
    expect((await first.load()).drafts.single.syncStatus, 'pending');
    expect((await first.load()).syncNotice, isNotNull);
    await first.synchronize();
    expect(cloud.records, hasLength(1));
    expect(cloud.records.values.single['version'], 1);
    expect((await first.load()).drafts.single.syncStatus, 'synced');
  });

  test(
      'two-device conflict preserves local work and can keep it as a separate draft',
      () async {
    final first = repo(), second = repo(other: true);
    await first.save(const ActivityDraft(groupId: '', title: 'Original'));
    online = true;
    await first.synchronize();
    await second.synchronize();
    online = false;
    await first.save(const ActivityDraft(groupId: '', title: 'Local edit'),
        previous: (await first.load()).drafts.single);
    await second.save(const ActivityDraft(groupId: '', title: 'Cloud edit'),
        previous: (await second.load()).drafts.single);
    online = true;
    await second.synchronize();
    await first.synchronize();
    final conflict = (await first.load()).drafts.single;
    expect(conflict.syncStatus, 'conflict');
    expect(conflict.activity.title, 'Local edit');
    await first.resolveConflict(conflict, keepLocalCopy: true);
    final recovered = (await first.load()).drafts;
    expect(recovered.map((r) => r.activity.title),
        containsAll(['Local edit', 'Cloud edit']));
    expect(recovered.every((r) => r.syncStatus == 'synced'), isTrue);
    expect(cloud.records, hasLength(2));
  });

  test(
      'an edit during cloud request is not overwritten by its older acknowledgement',
      () async {
    final first = repo();
    await first.save(const ActivityDraft(groupId: '', title: 'Before'));
    final previous = (await first.load()).drafts.single;
    final gate = Completer<void>(), started = Completer<void>();
    cloud.gate = gate;
    cloud.started = started;
    online = true;
    final syncing = first.synchronize();
    await started.future;
    await first.save(const ActivityDraft(groupId: '', title: 'During sync'),
        previous: previous);
    gate.complete();
    await syncing;
    expect((await first.load()).drafts.single.activity.title, 'During sync');
    expect(cloud.records.values.single['payload']['title'], 'During sync');
    expect((await first.load()).drafts.single.syncStatus, 'synced');
  });

  test(
      'version-one database migrates existing drafts into a durable sync queue',
      () async {
    final path = '${dir.path}/legacy.sqlite';
    final legacy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) => db.execute(
                'CREATE TABLE activity_drafts (namespace TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL, updated_at INTEGER NOT NULL, category TEXT NOT NULL, state TEXT NOT NULL, payload TEXT, PRIMARY KEY(namespace,id))')));
    await legacy.insert('activity_drafts', {
      'namespace': 'test/alice',
      'id': 'old',
      'revision': 1,
      'updated_at': 1,
      'category': 'study',
      'state': 'active',
      'payload': jsonEncode({
        'groupId': '',
        'title': 'Legacy',
        'description': '',
        'category': 'study',
        'location': '',
        'status': 'PROPOSED',
        'date': '',
        'time': ''
      })
    });
    await legacy.close();
    final migrated = await SqliteActivityDraftsRepository.openDatabaseForDrafts(
        factory: databaseFactoryFfi, path: path);
    final row = (await migrated.query('activity_drafts')).single;
    expect(row['pending'], 1);
    expect(row['operation_id'], isNotEmpty);
    await migrated.close();
  });

  test(
      'comparison reuses its RAM result, invalidates revisions and is empty in a new cache',
      () {
    SavedActivityDraft record(String id, int revision) => SavedActivityDraft(
        id: id,
        revision: revision,
        updatedAt: DateTime.utc(2030),
        activity: ActivityDraft(groupId: '', title: id));
    final a = record('a', 1),
        b = record('b', 1),
        cache = DraftComparisonCache();
    final result = cache.compare(a, b);
    expect(identical(cache.compare(a, b), result), isTrue);
    cache.reconcile([a, b]);
    expect(cache.result, same(result));
    cache.reconcile([record('a', 2), b]);
    expect(cache.result, isNull);
    expect(DraftComparisonCache().result, isNull);
    expect(DraftComparisonCache().leftId, isNull);
  });
}
