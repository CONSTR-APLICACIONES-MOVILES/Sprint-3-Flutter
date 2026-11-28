import 'package:sqflite/sqflite.dart';
import '../../domain/entities/andes_event.dart';
import '../../domain/repositories/saved_andes_events_repository.dart';

/// A separate database keeps saved snapshots independent of the offline cache.
class SqliteSavedAndesEventsRepository implements SavedAndesEventsRepository {
  final Future<Database> Function() _open;
  Future<Database>? _pending;
  SqliteSavedAndesEventsRepository._(this._open);
  Future<Database> get _database => _pending ??= _open().catchError((Object error, StackTrace stack) {
    _pending = null;
    Error.throwWithStackTrace(error, stack);
  });

  factory SqliteSavedAndesEventsRepository(
      {String? path, DatabaseFactory? factory}) {
    Future<Database> open() async {
      final selected = factory ?? databaseFactory;
      final file = path ??
          '${await selected.getDatabasesPath()}/parchapp-saved-andes-events.sqlite';
      return selected.openDatabase(file,
          options: OpenDatabaseOptions(
              version: 1,
              onCreate: (db, _) => db.execute(
                  'CREATE TABLE saved_andes_events ('
                  'user_id TEXT NOT NULL, event_id TEXT NOT NULL, title TEXT NOT NULL, '
                  'category TEXT NOT NULL, description TEXT NOT NULL, location TEXT NOT NULL, '
                  'start_at INTEGER NOT NULL, end_at INTEGER NOT NULL, saved_at INTEGER NOT NULL, '
                  'source_url TEXT, PRIMARY KEY (user_id, event_id))')));
    }

    return SqliteSavedAndesEventsRepository._(open);
  }
  String _user(String userId) {
    if (userId.isEmpty)
      throw StateError('Please sign in to access saved events.');
    return userId;
  }

  @override
  Future<List<AndesEvent>> getSaved(String userId) async {
    final rows = await (await _database).query('saved_andes_events',
        where: 'user_id = ?',
        whereArgs: [_user(userId)],
        orderBy: 'start_at ASC, event_id ASC');
    return rows
        .map((row) => AndesEvent(
            id: row['event_id'] as String,
            title: row['title'] as String,
            category: row['category'] as String,
            description: row['description'] as String,
            location: row['location'] as String,
            start: DateTime.fromMillisecondsSinceEpoch(row['start_at'] as int),
            end: DateTime.fromMillisecondsSinceEpoch(row['end_at'] as int),
            sourceUrl: row['source_url'] as String?))
        .toList();
  }

  @override
  Future<bool> isSaved(String userId, String eventId) async =>
      (await (await _database).query('saved_andes_events',
              columns: ['event_id'],
              where: 'user_id = ? AND event_id = ?',
              whereArgs: [_user(userId), eventId],
              limit: 1))
          .isNotEmpty;
  @override
  Future<void> save(String userId, AndesEvent event) async {
    await (await _database).insert(
        'saved_andes_events',
        {
          'user_id': _user(userId),
          'event_id': event.id,
          'title': event.title,
          'category': event.category,
          'description': event.description,
          'location': event.location,
          'start_at': event.start.millisecondsSinceEpoch,
          'end_at': event.end.millisecondsSinceEpoch,
          'saved_at': DateTime.now().millisecondsSinceEpoch,
          'source_url': event.sourceUrl
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> remove(String userId, String eventId) async {
    await (await _database).delete('saved_andes_events',
        where: 'user_id = ? AND event_id = ?',
        whereArgs: [_user(userId), eventId]);
  }

  Future<void> close() async => (await _database).close();
}
