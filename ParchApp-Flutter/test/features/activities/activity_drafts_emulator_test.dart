import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parchapp/features/activities/data/repositories/sqlite_activity_drafts_repository.dart';
import 'package:parchapp/features/activities/domain/entities/activity_draft.dart';

// An opt-in integration test: real HTTP callables + Auth/Firestore emulators,
// and two independent SQLite stores. It never accepts production endpoints.
void main() {
  const enabled = bool.fromEnvironment('DRAFTS_EMULATOR_TEST');
  test(
      'Flutter SQL outbox round-trips through real emulator callables across two installations',
      () async {
    sqfliteFfiInit();
    final http = HttpClient();
    final dir = await Directory.systemTemp.createTemp('draft-emulator-');
    Future<Map<String, dynamic>> post(String url, Map<String, dynamic> data,
        [String? token]) async {
      final request = await http.postUrl(Uri.parse(url));
      request.headers.contentType = ContentType.json;
      if (token != null) request.headers.set('Authorization', 'Bearer $token');
      request.write(jsonEncode(data));
      final response = await request.close();
      final decoded = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      if (response.statusCode >= 400) {
        throw StateError(
            'Emulator HTTP ${response.statusCode}: ${decoded['error']?['status']}');
      }
      return decoded;
    }

    Future<Map<String, dynamic>> signup() => post(
        'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=emulator-only',
        {'returnSecureToken': true});
    final auth = await signup(), otherAuth = await signup();
    final uid = auth['localId'] as String;
    Future<Map<String, dynamic>> call(String name, Map<String, dynamic> data,
        [Map<String, dynamic>? user]) async {
      final result = await post(
          'http://127.0.0.1:5001/demo-parchapp-drafts/us-central1/$name',
          {'data': data},
          (user ?? auth)['idToken'] as String);
      return Map<String, dynamic>.from(result['result'] as Map);
    }

    final firstDb = await SqliteActivityDraftsRepository.openDatabaseForDrafts(
        factory: databaseFactoryFfi, path: '${dir.path}/one.sqlite');
    final secondDb = await SqliteActivityDraftsRepository.openDatabaseForDrafts(
        factory: databaseFactoryFfi, path: '${dir.path}/two.sqlite');
    var online = false;
    final first = SqliteActivityDraftsRepository(
        open: () async => firstDb,
        namespace: 'demo-parchapp-drafts/$uid',
        sessionIsCurrent: () => true,
        canAttemptRemote: () => online,
        remoteCall: call);
    final second = SqliteActivityDraftsRepository(
        open: () async => secondDb,
        namespace: 'demo-parchapp-drafts/$uid',
        sessionIsCurrent: () => true,
        canAttemptRemote: () => online,
        remoteCall: call);
    try {
      await first.save(const ActivityDraft(
          groupId: '',
          title: 'Emulator persisted plan',
          requestId: 'draft-http'));
      expect((await first.load()).drafts.single.syncStatus, 'pending');
      online = true;
      await first.synchronize();
      expect((await first.load()).drafts.single.syncStatus, 'synced');
      await second.synchronize();
      expect((await second.load()).drafts.single.activity.title,
          'Emulator persisted plan');
      expect(
          (await call('getActivityDrafts', {}, otherAuth))['drafts'], isEmpty);
      online = false;
      await first.delete((await first.load()).drafts.single);
      online = true;
      await first.synchronize();
      await second.synchronize();
      expect((await second.load()).drafts, isEmpty);
      expect(
          ((await call('getActivityDrafts', {}))['drafts'] as List)
              .single['state'],
          'deleted');
    } finally {
      await first.synchronize();
      await firstDb.close();
      await secondDb.close();
      http.close(force: true);
      await dir.delete(recursive: true);
    }
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 2)));
}
