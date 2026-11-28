import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parchapp/features/andes_events/data/repositories/sqlite_saved_andes_events_repository.dart';
import 'package:parchapp/features/andes_events/domain/entities/andes_event.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_repository.dart';
import 'package:parchapp/features/andes_events/presentation/view_models/andes_events_view_model.dart';
import 'package:parchapp/features/andes_events/presentation/views/andes_events_view.dart';

class OfflineCatalog implements AndesEventsRepository {
  int writes = 0;
  @override Future<AndesEventsResult> load() async => throw StateError('Offline');
  @override Future<Set<String>> addedIds() async => throw StateError('Offline');
  @override Future<void> remove(AndesEvent event) async {}
  @override Future<void> add(AndesEvent event) async { writes++; }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late SqliteSavedAndesEventsRepository db;
  final start = DateTime.utc(2031, 2, 3, 12, 45);
  late AndesEvent event;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('saved-events-');
    db = SqliteSavedAndesEventsRepository(path: '${dir.path}/events.sqlite', factory: databaseFactoryFfi);
    event = AndesEvent(id: 'event', title: 'Lecture', category: 'academic', description: 'Local details', location: 'Campus', start: start, end: start.add(const Duration(hours: 1)));
  });
  tearDown(() async { await db.close(); await dir.delete(recursive: true); });
  test('save, deduplicate, isolate accounts, reopen and remove', () async {
    await db.save('user-a', event);
    await db.save('user-a', event);
    expect(await db.isSaved('user-a', event.id), isTrue);
    expect(await db.getSaved('user-b'), isEmpty);
    expect(await db.getSaved('user-a'), hasLength(1));
    await db.close();
    db = SqliteSavedAndesEventsRepository(path: '${dir.path}/events.sqlite', factory: databaseFactoryFfi);
    final saved = (await db.getSaved('user-a')).single;
    expect(saved.start.toUtc(), start);
    expect(saved.end.toUtc(), event.end);
    expect(saved.description, 'Local details');
    await db.remove('user-a', event.id);
    await db.remove('user-a', event.id);
    expect(await db.isSaved('user-a', event.id), isFalse);
    await expectLater(db.getSaved(''), throwsStateError);
  });
  testWidgets('saved tab works offline, bookmark removes and does not add to schedule', (tester) async {
    await tester.runAsync(() => db.save('user-a', event));
    final catalog = OfflineCatalog();
    final vm = AndesEventsViewModel(catalog, savedRepository: db, userId: 'user-a');
    final router = GoRouter(initialLocation: '/events', routes: [GoRoute(path: '/events', builder: (_, __) => AndesEventsView(viewModel: vm)), GoRoute(path: '/schedule', builder: (_, __) => const Scaffold())]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 100)); });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saved (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Lecture'), findsOneWidget);
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    expect(find.textContaining('may not be up to date'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove from Saved'));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 100)); });
    await tester.pumpAndSettle();
    expect(find.textContaining('No saved events yet'), findsOneWidget);
    expect(catalog.writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
  });
  test('account switch clears old snapshots and reloads independently', () async {
    await db.save('a', event);
    final accounts = StreamController<String?>();
    final vm = AndesEventsViewModel(OfflineCatalog(), savedRepository: db, userId: 'a', accountChanges: accounts.stream);
    await vm.refreshSaved();
    expect(vm.savedEvents, hasLength(1));
    accounts.add('b');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(vm.savedEvents, isEmpty);
    accounts.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(vm.savedError, 'Sign in to access saved events.');
    vm.dispose(); await accounts.close();
  });
}
