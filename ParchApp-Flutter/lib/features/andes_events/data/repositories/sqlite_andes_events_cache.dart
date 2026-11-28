import 'package:sqflite/sqflite.dart';
import '../../domain/entities/andes_event.dart';
import '../../domain/repositories/andes_events_cache.dart';

class SqliteAndesEventsCache implements AndesEventsCache, AndesCacheIdentity {
  @override
  Object get coordinationKey => (path ?? 'parchapp-andes-catalog.sqlite', namespace);
  final String namespace;
  final String? path;
  final DatabaseFactory? factory;
  Future<Database>? _opening;
  SqliteAndesEventsCache({required this.namespace, this.path, this.factory});
  Future<Database> get database => _opening ??= _open().catchError((Object e, StackTrace s) {
    _opening = null;
    Error.throwWithStackTrace(e, s);
  });
  Future<Database> _open() async {
    final selected = factory ?? databaseFactory;
    final file = path ?? '${await selected.getDatabasesPath()}/parchapp-andes-catalog.sqlite';
    return selected.openDatabase(file, options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
      await db.execute('CREATE TABLE cached_andes_events (namespace TEXT NOT NULL, event_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT NOT NULL, category TEXT NOT NULL, location TEXT NOT NULL, start_at INTEGER NOT NULL, end_at INTEGER NOT NULL, cached_at INTEGER NOT NULL, source_url TEXT, PRIMARY KEY(namespace, event_id))');
      await db.execute('CREATE TABLE andes_cache_metadata (namespace TEXT PRIMARY KEY NOT NULL, last_successful_sync_at INTEGER NOT NULL)');
    }));
  }
  @override
  Future<AndesCacheSnapshot> read(AndesCacheWindow window) async => (await database).transaction((tx) async {
    await tx.delete('cached_andes_events', where: 'namespace = ? AND (end_at <= ? OR end_at <= ? OR start_at >= ?)', whereArgs: [namespace, window.now.millisecondsSinceEpoch, window.start.millisecondsSinceEpoch, window.end.millisecondsSinceEpoch]);
    final rows = await tx.query('cached_andes_events', where: 'namespace = ?', whereArgs: [namespace], orderBy: 'start_at ASC');
    final meta = await tx.query('andes_cache_metadata', where: 'namespace = ?', whereArgs: [namespace], limit: 1);
    return AndesCacheSnapshot(rows.map((r) => AndesEvent(id: r['event_id'] as String, title: r['title'] as String, description: r['description'] as String, category: r['category'] as String, location: r['location'] as String, start: DateTime.fromMillisecondsSinceEpoch(r['start_at'] as int), end: DateTime.fromMillisecondsSinceEpoch(r['end_at'] as int), sourceUrl: r['source_url'] as String?)).toList(), meta.isEmpty ? null : DateTime.fromMillisecondsSinceEpoch(meta.first['last_successful_sync_at'] as int));
  });
  @override
  Future<void> replace(List<AndesEvent> events, AndesCacheWindow window, DateTime syncedAt) async => (await database).transaction((tx) async {
    await tx.delete('cached_andes_events', where: 'namespace = ?', whereArgs: [namespace]);
    final batch = tx.batch();
    for (final e in events.where(window.includes)) {
      batch.insert('cached_andes_events', {'namespace': namespace, 'event_id': e.id, 'title': e.title, 'description': e.description, 'category': e.category, 'location': e.location, 'start_at': e.start.millisecondsSinceEpoch, 'end_at': e.end.millisecondsSinceEpoch, 'cached_at': syncedAt.millisecondsSinceEpoch, 'source_url': e.sourceUrl}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    batch.insert('andes_cache_metadata', {'namespace': namespace, 'last_successful_sync_at': syncedAt.millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  });
  Future<void> close() async { if (_opening != null) await (await _opening!).close(); }
}
