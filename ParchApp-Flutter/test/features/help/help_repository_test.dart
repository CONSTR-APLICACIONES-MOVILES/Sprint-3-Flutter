import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parchapp/features/help/data/help_repository.dart';
import 'package:parchapp/features/help/domain/help_faq.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late HelpRepository repository;
  late SharedPreferences preferences;
  Future<HelpRepository> open() => HelpRepository.open(path: '${directory.path}/help.sqlite', factory: databaseFactoryFfi, preferences: preferences, readAsset: () => File('assets/data/help_faq.json').readAsString(), eligible: () async => false);
  setUp(() async { directory = await Directory.systemTemp.createTemp('help-test-'); SharedPreferences.setMockInitialValues({}); preferences = await SharedPreferences.getInstance(); repository = await open(); });
  tearDown(() async { await repository.database.close(); await directory.delete(recursive: true); });
  test('bundled FAQs persist, sections follow origin and General remains last', () async {
    final rows = await repository.all();
    expect(rows, hasLength(14)); expect(rows.first.screen, 'alerts');
    final groups = helpSectionOrder(rows, 'groups'); expect(groups.first, 'groups'); expect(groups.last, 'general');
    expect(helpSectionOrder(rows, 'general').last, 'general');
    expect(rows.where((f) => f.screen == 'groups').map((f) => f.position), [1, 2, 3]);
    await repository.database.close(); repository = await open();
    expect(await repository.all(), hasLength(14)); expect(repository.lastSync, isNull);
  });
  test('offline FTS search normalizes text and matches word prefixes safely', () async {
    expect(normalizeHelpQuery('  Create   GROUP '), 'create group');
    expect(helpMatchQuery('Create-group!!'), 'create* group*');
    expect((await repository.search('CREA  gro')).map((f) => f.id), contains('groups-create'));
    expect((await repository.search('sched with')).map((f) => f.id), contains('schedule-offline'));
    expect(helpMatchQuery('!!!'), isEmpty);
    expect(await repository.refresh(), isFalse); expect(await repository.all(), hasLength(14));
  });
  test('successful sync invalidates search cache; failed or empty refresh preserves data', () async {
    var now = DateTime(2030, 1, 1);
    var fail = false, empty = false;
    final sync = HelpRepository(repository.database, preferences, eligible: () async => true, clock: () => now, fetchRemote: () async {
      if (fail) throw StateError('network');
      if (empty) return [];
      return [const HelpFaq(id: 'updated', screen: 'groups', question: 'Create new group', answer: 'Updated information', position: 1)];
    });
    expect((await sync.search('crea')).first.id, 'groups-create');
    expect(await sync.refresh(), isTrue);
    expect((await sync.search('crea')).single.id, 'updated');
    final savedAt = sync.lastSync;
    now = now.add(const Duration(days: 2)); fail = true;
    expect(await sync.refresh(), isFalse); expect(sync.lastSync, savedAt);
    now = now.add(const Duration(minutes: 31)); fail = false; empty = true;
    expect(await sync.refresh(), isFalse); expect((await sync.all()).single.id, 'updated');
  });

}
