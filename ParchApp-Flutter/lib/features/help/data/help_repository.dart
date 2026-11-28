import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../domain/help_faq.dart';

class HelpRepository {
  final Database database;
  final SharedPreferences preferences;
  final FirebaseFirestore? firestore;
  final Future<List<HelpFaq>> Function()? fetchRemote;
  final Future<bool> Function() eligible;
  final DateTime Function() clock;
  final Map<String, List<HelpFaq>> _searches = {};
  bool _fts = false;
  Future<bool>? _refreshing;
  HelpRepository(this.database, this.preferences, {this.firestore, this.fetchRemote, required this.eligible, DateTime Function()? clock}) : clock = clock ?? DateTime.now;
  static Future<HelpRepository> open({FirebaseFirestore? firestore, DatabaseFactory? factory, String? path, SharedPreferences? preferences, Future<bool> Function()? eligible, Future<String> Function()? readAsset, Future<List<HelpFaq>> Function()? fetchRemote, DateTime Function()? clock}) async {
    final dbFactory = factory ?? databaseFactory;
    final db = await dbFactory.openDatabase(path ?? '${await dbFactory.getDatabasesPath()}/parchapp-help.sqlite', options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
      try {
        await db.execute('CREATE VIRTUAL TABLE help_faq USING fts4(id, screen, question, answer, position, notindexed=id, notindexed=screen, notindexed=position)');
      } catch (_) {
        await db.execute('CREATE TABLE help_faq (id TEXT PRIMARY KEY, screen TEXT NOT NULL, question TEXT NOT NULL, answer TEXT NOT NULL, position INTEGER NOT NULL)');
      }
    }));
    final repository = HelpRepository(db, preferences ?? await SharedPreferences.getInstance(), firestore: firestore, fetchRemote: fetchRemote, clock: clock, eligible: eligible ?? canRefreshOnWifi);
    final schema = await db.rawQuery("SELECT sql FROM sqlite_master WHERE name = 'help_faq'");
    repository._fts = (schema.first['sql'] as String).toLowerCase().contains('virtual table');
    final seed = jsonDecode(await (readAsset ?? () => rootBundle.loadString('assets/data/help_faq.json'))()) as List;
    await db.transaction((tx) async {
      final count = Sqflite.firstIntValue(await tx.rawQuery('SELECT COUNT(*) FROM help_faq')) ?? 0;
      if (count == 0) { final batch = tx.batch(); for (final item in seed) { batch.insert('help_faq', HelpFaq.fromMap(Map<String, dynamic>.from(item as Map)).toMap()); } await batch.commit(noResult: true); }
    });
    return repository;
  }
  static Future<bool> canRefreshOnWifi() async {
    try { return await const MethodChannel('parchapp/help_refresh').invokeMethod<bool>('eligible') ?? false; } catch (_) { return false; }
  }
  DateTime? get lastSync { final value = preferences.getInt('help.lastSync') ?? 0; return value == 0 ? null : DateTime.fromMillisecondsSinceEpoch(value); }
  HelpFaq _map(Map<String, Object?> row) => HelpFaq.fromMap({'id': row['id'], 'screen': row['screen'], 'question': row['question'], 'answer': row['answer'], 'position': int.tryParse('${row['position']}') ?? 0});
  Future<List<HelpFaq>> all() async => (await database.query('help_faq', orderBy: 'screen, CAST(position AS INTEGER)')).map(_map).toList();
  Future<List<HelpFaq>> search(String text) async {
    final key = normalizeHelpQuery(text), match = helpMatchQuery(text);
    if (match.isEmpty) return all();
    final cached = _searches[key]; if (cached != null) return cached;
    final List<HelpFaq> rows;
    if (_fts) {
      rows = (await database.rawQuery('SELECT * FROM help_faq WHERE help_faq MATCH ? ORDER BY CAST(position AS INTEGER)', [match])).map(_map).toList();
    } else {
      final terms = match.split(' ').map((s) => s.substring(0, s.length - 1));
      rows = (await all()).where((faq) {
        final words = RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches('${faq.question} ${faq.answer}'.toLowerCase()).map((m) => m.group(0)!);
        return terms.every((term) => words.any((word) => word.startsWith(term)));
      }).toList()..sort((a, b) => a.position.compareTo(b.position));
    }
    if (_searches.length >= 20) _searches.remove(_searches.keys.first);
    _searches[key] = rows; return rows;
  }
  Future<bool> refresh() {
    if (_refreshing != null) return _refreshing!;
    final future = _refresh(); _refreshing = future;
    return future.whenComplete(() { if (identical(_refreshing, future)) _refreshing = null; });
  }
  Future<bool> _refresh() async {
    final remote = firestore;
    if ((remote == null && fetchRemote == null) || !await eligible()) return false;
    final now = clock().millisecondsSinceEpoch;
    final sync = preferences.getInt('help.lastSync') ?? 0;
    final attempt = preferences.getInt('help.lastAttempt') ?? 0;
    if ((sync != 0 && now - sync < const Duration(hours: 24).inMilliseconds) || (attempt != 0 && now - attempt < const Duration(minutes: 30).inMilliseconds)) return false;
    await preferences.setInt('help.lastAttempt', now);
    try {
      final List<HelpFaq> rows;
      if (fetchRemote != null) {
        rows = await fetchRemote!().timeout(const Duration(seconds: 8));
      } else {
        final docs = await remote!.collection('helpFaq').where('active', isEqualTo: true).get(const GetOptions(source: Source.server)).timeout(const Duration(seconds: 8));
        rows = <HelpFaq>[];
        for (final doc in docs.docs) { try { final faq = HelpFaq.fromMap(doc.data(), documentId: doc.id); if (faq.question.isNotEmpty && faq.answer.isNotEmpty && faq.screen.isNotEmpty) rows.add(faq); } catch (_) {} }
      }
      if (rows.isEmpty) return false;
      await database.transaction((tx) async { await tx.delete('help_faq'); final batch = tx.batch(); for (final faq in rows) { batch.insert('help_faq', faq.toMap()); } await batch.commit(noResult: true); });
      _searches.clear(); await preferences.setInt('help.lastSync', clock().millisecondsSinceEpoch); return true;
    } catch (_) { return false; }
  }
}
