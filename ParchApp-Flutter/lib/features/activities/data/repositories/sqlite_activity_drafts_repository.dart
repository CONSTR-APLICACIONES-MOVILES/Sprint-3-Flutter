import 'dart:convert';
import 'dart:math';
import 'dart:developer';
import 'dart:async';
import 'package:sqflite/sqflite.dart';
import '../../domain/entities/activity_draft.dart';
import '../../domain/entities/activity_location.dart';
import '../../domain/entities/planning_context.dart';
import '../../domain/entities/study_session.dart';
import '../../domain/repositories/activity_drafts_repository.dart';

/// A session-bound store. SQLite performs native disk work asynchronously;
/// the queue orders read/modify/write operations and survives operation errors.
class SqliteActivityDraftsRepository
    implements ObservableActivityDraftsRepository {
  final Future<Database> Function() open;
  final bool Function() sessionIsCurrent;
  final String namespace;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
      remoteCall;
  final bool Function()? canAttemptRemote;
  Future<void>? _syncing;
  bool _syncAgain = false;
  bool _connectionUnavailable = false;
  String? _syncNotice;
  final _changes = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => _changes.stream;
  @override
  bool get isOffline =>
      canAttemptRemote?.call() == false || _connectionUnavailable;
  void _notify() => _changes.add(null);
  Future<void> _tail = Future.value();
  DraftsSnapshot? _cache;
  SqliteActivityDraftsRepository(
      {required this.open,
      required this.namespace,
      this.remoteCall,
      this.canAttemptRemote,
      required this.sessionIsCurrent});

  static Future<Database>? _database;
  static Future<Database> openDefault() => _database ??=
          openDatabaseForDrafts().catchError((Object error, StackTrace stack) {
        _database = null;
        Error.throwWithStackTrace(error, stack);
      });

  static Future<Database> openDatabaseForDrafts(
      {DatabaseFactory? factory, String? path}) async {
    final selected = factory ?? databaseFactory;
    return selected.openDatabase(
        path ?? '${await selected.getDatabasesPath()}/parchapp-drafts.sqlite',
        options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, _) async {
              await db.execute('CREATE TABLE activity_drafts ('
                  'namespace TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL, '
                  'updated_at INTEGER NOT NULL, category TEXT NOT NULL, '
                  'state TEXT NOT NULL, payload TEXT, remote_version INTEGER NOT NULL DEFAULT 0, '
                  'pending INTEGER NOT NULL DEFAULT 1, operation_id TEXT NOT NULL DEFAULT "", '
                  'sync_error TEXT, request_key TEXT, PRIMARY KEY(namespace, id))');
              await db.execute(
                  'CREATE INDEX draft_list ON activity_drafts(namespace, state, updated_at DESC)');
            },
            onUpgrade: (db, oldVersion, newVersion) async {
              if (oldVersion < 2) {
                await db.execute(
                    'ALTER TABLE activity_drafts ADD COLUMN remote_version INTEGER NOT NULL DEFAULT 0');
                await db.execute(
                    'ALTER TABLE activity_drafts ADD COLUMN pending INTEGER NOT NULL DEFAULT 1');
                await db.execute(
                    'ALTER TABLE activity_drafts ADD COLUMN operation_id TEXT NOT NULL DEFAULT ""');
                await db.execute(
                    'ALTER TABLE activity_drafts ADD COLUMN sync_error TEXT');
                await db.execute(
                    'ALTER TABLE activity_drafts ADD COLUMN request_key TEXT');
                await db.execute(
                    'UPDATE activity_drafts SET operation_id = lower(hex(randomblob(24)))');
                // Legacy published rows no longer retain a publication receipt.
                // Preserve their local history without claiming cloud attribution.
                await db.execute(
                    "UPDATE activity_drafts SET pending = 0 WHERE state = 'published'");
              }
            }));
  }

  void _checkSession() {
    if (!sessionIsCurrent()) {
      throw const SessionFailure('Your account changed. Reopen New Activity.');
    }
  }

  Future<T> _ordered<T>(Future<T> Function() action) {
    final next = _tail.then((_) async {
      _checkSession();
      final result = await action();
      _checkSession();
      return result;
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  static Map<String, dynamic> _encode(ActivityDraft d) => {
        'groupId': d.groupId,
        'title': d.title,
        'description': d.description,
        'category': d.category,
        'location': d.location,
        'status': d.status,
        'date': d.date,
        'time': d.time,
        'measurementVersion': d.measurementVersion,
        'requestId': d.requestId,
        'locationDetails': d.locationDetails?.toMap(),
        'startsAt': d.startsAt?.toUtc().toIso8601String(),
        'endsAt': d.endsAt?.toUtc().toIso8601String(),
        'planning': d.planning == null
            ? null
            : {
                ...d.planning!.toMap(),
                'comparisonId': d.planning!.comparisonId,
                'comparisonEvidenceId': d.planning!.comparisonEvidenceId,
                'expiresAt': d.planning!.expiresAt?.toUtc().toIso8601String()
              },
        'comparison': d.comparison?.toMap(),
      };

  static ActivityDraft _decode(String raw) {
    final d = jsonDecode(raw) as Map<String, dynamic>;
    return ActivityDraft(
        groupId: d['groupId'] as String,
        title: d['title'] as String,
        description: d['description'] as String,
        category: d['category'] as String,
        location: d['location'] as String,
        status: d['status'] as String,
        date: d['date'] as String,
        time: d['time'] as String,
        measurementVersion: d['measurementVersion'] as int?,
        requestId: d['requestId'] as String?,
        locationDetails: ActivityLocation.fromMap(d['locationDetails']),
        startsAt: d['startsAt'] == null
            ? null
            : DateTime.parse(d['startsAt'] as String),
        endsAt:
            d['endsAt'] == null ? null : DateTime.parse(d['endsAt'] as String),
        planning: d['planning'] == null
            ? null
            : PlanningContext.fromMap(
                Map<String, dynamic>.from(d['planning'] as Map)),
        comparison: d['comparison'] == null
            ? null
            : CreationComparison.fromMap(
                Map<String, dynamic>.from(d['comparison'] as Map)));
  }

  @override
  Future<DraftsSnapshot> load({bool refresh = false}) => _ordered(() async {
        // A controlled baseline for profiling the same dataset without cache.
        const bypassCache = bool.fromEnvironment('DRAFTS_BYPASS_CACHE');
        if (!refresh && !bypassCache && _cache != null) {
          Timeline.instantSync('activity_drafts.cache_hit');
          return _cache!;
        }
        final db = await open();
        _checkSession();
        final task = TimelineTask()..start('activity_drafts.disk_load');
        try {
          final rows = await db.query('activity_drafts',
              where: "namespace = ? AND (state = ? OR sync_error = 'conflict')",
              whereArgs: [namespace, 'active'],
              orderBy: 'updated_at DESC, id');
          final totals = await db.rawQuery(
              'SELECT category, COUNT(*) AS saved, '
              "SUM(CASE WHEN state = 'published' THEN 1 ELSE 0 END) AS published "
              'FROM activity_drafts WHERE namespace = ? GROUP BY category ORDER BY category',
              [namespace]);
          final result = DraftsSnapshot(
              List.unmodifiable(rows.map((r) => SavedActivityDraft(
                  id: r['id'] as String,
                  revision: r['revision'] as int,
                  updatedAt: DateTime.fromMillisecondsSinceEpoch(
                      r['updated_at'] as int,
                      isUtc: true),
                  activity: r['payload'] == null
                      ? ActivityDraft(
                          groupId: '',
                          title: '${r['state']} draft — sync conflict',
                          category: r['category'] as String)
                      : _decode(r['payload'] as String),
                  localState: r['state'] as String,
                  syncStatus: remoteCall == null
                      ? 'local'
                      : r['sync_error'] == 'conflict'
                          ? 'conflict'
                          : r['pending'] == 1
                              ? 'pending'
                              : 'synced'))),
              List.unmodifiable(totals.map((r) => DraftCategoryHistory(
                  r['category'] as String,
                  r['saved'] as int,
                  r['published'] as int))),
              syncNotice: _syncNotice);
          _checkSession();
          return _cache = result;
        } finally {
          task.finish();
        }
      });

  @override
  Future<SavedActivityDraft> save(ActivityDraft activity,
          {SavedActivityDraft? previous}) =>
      _ordered(() async {
        final task = TimelineTask()..start('activity_drafts.disk_save');
        try {
          final payload = jsonEncode(_encode(activity));
          if (utf8.encode(payload).length > 65536) {
            throw const SessionFailure('This draft is too large to save.');
          }
          final db = await open();
          _checkSession();
          final record = SavedActivityDraft(
              id: previous?.id ??
                  List.generate(
                      24,
                      (_) => Random.secure()
                          .nextInt(256)
                          .toRadixString(16)
                          .padLeft(2, '0')).join(),
              revision: (previous?.revision ?? 0) + 1,
              updatedAt: DateTime.now().toUtc(),
              activity: activity);
          await db.transaction((tx) async {
            _checkSession();
            final values = {
              'revision': record.revision,
              'updated_at': record.updatedAt.millisecondsSinceEpoch,
              'category': activity.category,
              'state': 'active',
              'payload': payload,
              'pending': 1,
              'operation_id': _newId(),
              'request_key': activity.requestId,
              // A conflict must be explicitly resolved, not silently overwritten.
            };
            if (previous == null) {
              await tx.insert('activity_drafts',
                  {...values, 'namespace': namespace, 'id': record.id});
            } else {
              final changed = await tx.update('activity_drafts', values,
                  where:
                      'namespace = ? AND id = ? AND revision = ? AND state = ?',
                  whereArgs: [
                    namespace,
                    previous.id,
                    previous.revision,
                    'active'
                  ]);
              if (changed != 1) {
                throw const SessionFailure(
                    'This draft changed. Open My drafts again before saving.');
              }
            }
          });
          _cache = null;
          _notify();
          if (remoteCall != null) unawaited(synchronize());
          return record;
        } finally {
          task.finish();
        }
      });

  Future<void> _finish(SavedActivityDraft record, String state) =>
      _ordered(() async {
        final db = await open();
        _checkSession();
        final changed = await db.update(
            'activity_drafts',
            {
              'state': state,
              'payload': null,
              'sync_error': null,
              'pending': 1,
              'operation_id': _newId()
            },
            where: 'namespace = ? AND id = ? AND revision = ? AND state = ?',
            whereArgs: [namespace, record.id, record.revision, 'active']);
        _cache = null;
        if (changed != 1) {
          throw const SessionFailure('This draft changed. Refresh My drafts.');
        }
        _notify();
        if (remoteCall != null) unawaited(synchronize());
      });

  @override
  Future<void> delete(SavedActivityDraft draft) => _finish(draft, 'deleted');
  @override
  Future<void> published(SavedActivityDraft draft) =>
      _finish(draft, 'published');

  static String _newId() => List.generate(24,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();

  @override
  Future<void> synchronize() {
    if (remoteCall == null ||
        canAttemptRemote?.call() == false ||
        !sessionIsCurrent()) {
      _notify();
      return Future.value();
    }
    if (_syncing != null) {
      _syncAgain = true;
      return _syncing!;
    }
    return _syncing = _runSync().whenComplete(() {
      _syncing = null;
      _notify();
    });
  }

  @override
  Future<void> retryPending() async {
    if (remoteCall == null ||
        canAttemptRemote?.call() == false ||
        !sessionIsCurrent()) {
      return;
    }
    final rows = await _ordered(() async => (await open()).query(
        'activity_drafts',
        columns: ['id'],
        where: 'namespace = ? AND pending = 1 AND sync_error IS NULL',
        whereArgs: [namespace],
        limit: 1));
    if (rows.isNotEmpty) await synchronize();
  }

  Future<void> _runSync() async {
    do {
      _syncAgain = false;
      if (!await _syncOnce() && !_syncAgain) break;
    } while (
        _syncAgain && sessionIsCurrent() && canAttemptRemote?.call() != false);
  }

  Future<Map<String, dynamic>> _remote(
      String name, Map<String, dynamic> input) async {
    _checkSession();
    if (canAttemptRemote?.call() == false) throw StateError('Offline');
    final result =
        await remoteCall!(name, input).timeout(const Duration(seconds: 8));
    _connectionUnavailable = false;
    _checkSession();
    return result;
  }

  Future<List<Map<String, Object?>>> _pending() =>
      _ordered(() async => (await open()).query('activity_drafts',
          where: 'namespace = ? AND pending = 1 AND sync_error IS NULL',
          whereArgs: [namespace],
          orderBy: 'updated_at'));

  Future<bool> _syncOnce() async {
    try {
      for (final row in await _pending()) {
        try {
          final payload = row['payload'] == null
              ? null
              : jsonDecode(row['payload'] as String);
          final result = await _remote('syncActivityDraft', {
            'id': row['id'],
            'operationId': row['operation_id'],
            'expectedVersion': row['remote_version'],
            'state': row['state'],
            'category': row['category'],
            'payload': payload,
            if (row['request_key'] != null || payload?['requestId'] != null)
              'requestId': row['request_key'] ?? payload['requestId'],
          });
          await _ordered(() async {
            final db = await open();
            await db.transaction((tx) async {
              final current = await tx.query('activity_drafts',
                  where: 'namespace = ? AND id = ?',
                  whereArgs: [namespace, row['id']]);
              if (current.isEmpty) return;
              if (current.single['operation_id'] == row['operation_id']) {
                await tx.update(
                    'activity_drafts',
                    {
                      'pending': 0,
                      'remote_version': result['version'],
                      'sync_error': null
                    },
                    where: 'namespace = ? AND id = ?',
                    whereArgs: [namespace, row['id']]);
              } else if (current.single['remote_version'] ==
                  row['remote_version']) {
                // A local edit happened while this request was in flight.
                // Advance only its cloud base; preserve its newer payload.
                await tx.update(
                    'activity_drafts', {'remote_version': result['version']},
                    where: 'namespace = ? AND id = ?',
                    whereArgs: [namespace, row['id']]);
                _syncAgain = true;
              }
            });
            _cache = null;
          });
        } catch (error) {
          // Firebase exceptions expose code; do not import Firebase into domain.
          String? code;
          try {
            code = (error as dynamic).code as String?;
          } catch (_) {}
          if (code != 'aborted' && code != 'failed-precondition') rethrow;
          await _ordered(() async {
            await (await open()).update(
                'activity_drafts', {'sync_error': 'conflict'},
                where: 'namespace = ? AND id = ?',
                whereArgs: [namespace, row['id']]);
            _cache = null;
          });
        }
      }
      String? cursor;
      final seen = <String>{};
      do {
        final page = await _remote(
            'getActivityDrafts', {if (cursor != null) 'cursor': cursor});
        for (final raw in page['drafts'] as List) {
          await _importCloud(Map<String, dynamic>.from(raw as Map));
        }
        cursor = page['nextCursor'] as String?;
        if (cursor != null && !seen.add(cursor)) {
          throw StateError('Invalid cloud pagination');
        }
      } while (cursor != null);
      _syncNotice = null;
      _cache = null;
      return true;
    } catch (error) {
      String? code;
      try {
        code = (error as dynamic).code as String?;
      } catch (_) {}
      _connectionUnavailable = error is TimeoutException ||
          {'unavailable', 'deadline-exceeded', 'network-request-failed'}
              .contains(code);
      _syncNotice =
          'Saved on this device. Changes will update automatically when a connection is available.';
      _cache = null;
      return false;
    }
  }

  Future<void> _importCloud(Map<String, dynamic> remote,
          {bool force = false}) =>
      _ordered(() async {
        final db = await open();
        await db.transaction((tx) async {
          final rows = await tx.query('activity_drafts',
              where: 'namespace = ? AND id = ?',
              whereArgs: [namespace, remote['id']]);
          final local = rows.firstOrNull;
          if (!force && local != null && local['pending'] == 1) {
            if (local['remote_version'] != remote['version']) {
              await tx.update('activity_drafts', {'sync_error': 'conflict'},
                  where: 'namespace = ? AND id = ?',
                  whereArgs: [namespace, remote['id']]);
            }
            return;
          }
          if (!force &&
              local != null &&
              local['remote_version'] == remote['version']) {
            return;
          }
          await tx.insert(
              'activity_drafts',
              {
                'namespace': namespace,
                'id': remote['id'],
                'revision': ((local?['revision'] as int?) ?? 0) + 1,
                'updated_at': DateTime.parse(remote['updatedAt'] as String)
                    .millisecondsSinceEpoch,
                'category': remote['category'],
                'state': remote['state'],
                'payload': remote['payload'] == null
                    ? null
                    : jsonEncode(remote['payload']),
                'remote_version': remote['version'],
                'pending': 0,
                'operation_id': _newId(),
                'sync_error': null,
                'request_key': remote['requestId']
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        });
        _cache = null;
      });

  @override
  Future<void> resolveConflict(SavedActivityDraft draft,
      {required bool keepLocalCopy}) async {
    // Fetch cloud first. A failed read must never discard the local draft.
    Map<String, dynamic>? cloud;
    String? cursor;
    do {
      final page = await _remote(
          'getActivityDrafts', {if (cursor != null) 'cursor': cursor});
      for (final raw in page['drafts'] as List) {
        if ((raw as Map)['id'] == draft.id) {
          cloud = Map<String, dynamic>.from(raw);
        }
      }
      cursor = page['nextCursor'] as String?;
    } while (cloud == null && cursor != null);
    if (cloud == null) {
      throw const SessionFailure(
          'Cloud draft is unavailable. Keep your local copy and retry.');
    }
    await _ordered(() async {
      final db = await open();
      await db.transaction((tx) async {
        final rows = await tx.query('activity_drafts',
            where: 'namespace = ? AND id = ? AND revision = ?',
            whereArgs: [namespace, draft.id, draft.revision]);
        if (rows.isEmpty) {
          throw const SessionFailure(
              'This draft changed. Refresh before resolving it.');
        }
        if (keepLocalCopy) {
          final copy = Map<String, Object?>.from(rows.single);
          final payload =
              jsonDecode(copy['payload'] as String) as Map<String, dynamic>;
          payload['requestId'] = _newId();
          copy.addAll({
            'id': _newId(),
            'revision': 1,
            'remote_version': 0,
            'pending': 1,
            'operation_id': _newId(),
            'sync_error': null,
            'request_key': payload['requestId'],
            'payload': jsonEncode(payload),
            'updated_at': DateTime.now().millisecondsSinceEpoch
          });
          await tx.insert('activity_drafts', copy);
        }
        await tx.update(
            'activity_drafts',
            {
              'revision': draft.revision + 1,
              'remote_version': cloud!['version'],
              'pending': 0,
              'sync_error': null,
              'state': cloud['state'],
              'category': cloud['category'],
              'payload': cloud['payload'] == null
                  ? null
                  : jsonEncode(cloud['payload']),
              'request_key': cloud['requestId'],
              'operation_id': _newId()
            },
            where: 'namespace = ? AND id = ?',
            whereArgs: [namespace, draft.id]);
      });
      _cache = null;
    });
    await synchronize();
  }
}
