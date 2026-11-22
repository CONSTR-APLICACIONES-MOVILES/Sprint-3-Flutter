import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../../domain/entities/andes_event.dart';
import '../../domain/services/schedule_outbox.dart';

class SqliteScheduleOutbox implements ScheduleOutboxStore {
  final String? path;
  final DatabaseFactory? factory;
  Future<Database>? _opening;
  SqliteScheduleOutbox({this.path, this.factory});
  Future<Database> get database => _opening ??= _open();
  Future<Database> _open() async {
    final f = factory ?? databaseFactory;
    return f.openDatabase(path ?? '${await f.getDatabasesPath()}/parchapp-schedule-outbox.sqlite', options: OpenDatabaseOptions(version: 1, onCreate: (db, _) => db.execute('CREATE TABLE pending_schedule_operations (user_id TEXT NOT NULL, event_id TEXT NOT NULL, operation_type TEXT NOT NULL, event_payload TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0, last_error TEXT, PRIMARY KEY (user_id, event_id, operation_type))')));
  }
  @override
  Future<void> enqueue(String userId, AndesEvent event) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (await database).insert('pending_schedule_operations', {'user_id': userId, 'event_id': event.id, 'operation_type': 'ADD_ANDES_EVENT', 'event_payload': jsonEncode({'title': event.title, 'description': event.description, 'category': event.category, 'location': event.location, 'start': event.start.millisecondsSinceEpoch, 'end': event.end.millisecondsSinceEpoch}), 'status': 'pending', 'created_at': now, 'updated_at': now}, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  @override
  Future<List<ScheduleIntent>> list(String userId) async {
    final rows = await (await database).query('pending_schedule_operations', where: 'user_id = ?', whereArgs: [userId], orderBy: 'created_at');
    return rows.map((r) { final data = jsonDecode(r['event_payload'] as String) as Map<String, dynamic>; return ScheduleIntent(userId, AndesEvent(id: r['event_id'] as String, title: data['title'] as String, description: data['description'] as String, category: data['category'] as String, location: data['location'] as String, start: DateTime.fromMillisecondsSinceEpoch(data['start'] as int), end: DateTime.fromMillisecondsSinceEpoch(data['end'] as int)), r['status'] as String, r['last_error'] as String?); }).toList();
  }
  @override
  Future<void> status(String userId, String eventId, String status, {String? error}) async {
    await (await database).rawUpdate('UPDATE pending_schedule_operations SET status = ?, updated_at = ?, last_error = ?, retry_count = retry_count + ? WHERE user_id = ? AND event_id = ? AND operation_type = ?', [status, DateTime.now().millisecondsSinceEpoch, error, status == 'syncing' ? 1 : 0, userId, eventId, 'ADD_ANDES_EVENT']);
  }
  @override
  Future<void> delete(String userId, String eventId) async => (await database).delete('pending_schedule_operations', where: 'user_id = ? AND event_id = ?', whereArgs: [userId, eventId]);
  @override
  Future<void> retryWithEvent(String userId, AndesEvent event) async {
    final payload = jsonEncode({'title': event.title, 'description': event.description, 'category': event.category, 'location': event.location, 'start': event.start.millisecondsSinceEpoch, 'end': event.end.millisecondsSinceEpoch});
    final updated = await (await database).update('pending_schedule_operations', {'event_payload': payload, 'status': 'pending', 'last_error': null, 'updated_at': DateTime.now().millisecondsSinceEpoch}, where: "user_id = ? AND event_id = ? AND operation_type = ? AND status = 'failed'", whereArgs: [userId, event.id, 'ADD_ANDES_EVENT']);
    if (updated != 1) throw StateError('The operation is no longer available for retry.');
  }
  @override
  Future<void> recover(String userId) async { await (await database).rawUpdate("UPDATE pending_schedule_operations SET status = 'pending' WHERE user_id = ? AND status = 'syncing'", [userId]); }
  Future<void> close() async { if (_opening != null) await (await _opening!).close(); }
}
