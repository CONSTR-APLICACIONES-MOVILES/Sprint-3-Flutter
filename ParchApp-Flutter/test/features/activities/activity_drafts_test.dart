import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parchapp/features/activities/data/repositories/sqlite_activity_drafts_repository.dart';
import 'package:parchapp/features/activities/data/repositories/firebase_study_sessions_repository.dart';
import 'package:parchapp/features/activities/domain/entities/activity_draft.dart';
import 'package:parchapp/features/activities/domain/entities/activity_location.dart';
import 'package:parchapp/features/activities/domain/entities/planning_context.dart';
import 'package:parchapp/features/activities/domain/entities/study_session.dart';
import 'package:parchapp/features/activities/domain/repositories/activity_drafts_repository.dart';
import 'package:parchapp/features/activities/domain/use_cases/manage_study_session.dart';
import 'package:parchapp/features/activities/presentation/view_models/activity_editor_view_model.dart';
import 'package:parchapp/features/activities/presentation/widgets/activity_form.dart';
import 'package:parchapp/features/activities/presentation/views/activity_drafts_view.dart';
import 'package:parchapp/features/activities/domain/entities/draft_comparison_cache.dart';
import 'firebase_study_sessions_repository_test.dart' show FakeActivitySource;
import 'activity_phase_b_test.dart' show RecoverableSource;

// Keep widget scheduling deterministic; durable persistence is exercised with
// real SQLite in the repository tests below, outside the widget fake clock.
class UiDrafts implements ActivityDraftsRepository {
  final records = <SavedActivityDraft>[];
  int _nextId = 0;
  List<DraftCategoryHistory> history = [];
  @override
  Future<DraftsSnapshot> load({bool refresh = false}) async =>
      DraftsSnapshot(List.of(records), history);
  @override
  Future<SavedActivityDraft> save(ActivityDraft activity,
      {SavedActivityDraft? previous}) async {
    final record = SavedActivityDraft(
        id: previous?.id ?? '${_nextId++}',
        revision: (previous?.revision ?? 0) + 1,
        updatedAt: DateTime.utc(2030),
        activity: activity);
    records.removeWhere((r) => r.id == record.id);
    records.add(record);
    return record;
  }

  @override
  Future<void> delete(SavedActivityDraft draft) async =>
      records.removeWhere((r) => r.id == draft.id);
  @override
  Future<void> published(SavedActivityDraft draft) => delete(draft);
}

class OfflineGroups extends FakeActivitySource {
  @override
  Future<List<Map<String, dynamic>>> listGroups() async =>
      throw const SessionFailure('Offline');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late Database db;
  String account = 'alice';
  SqliteActivityDraftsRepository store(
          [String uid = 'alice', String project = 'project']) =>
      SqliteActivityDraftsRepository(
          open: () async => db,
          namespace: '$project/$uid',
          sessionIsCurrent: () => account == uid);
  setUp(() async {
    account = 'alice';
    directory = await Directory.systemTemp.createTemp('parchapp-drafts-');
    db = await SqliteActivityDraftsRepository.openDatabaseForDrafts(
        factory: databaseFactoryFfi, path: '${directory.path}/drafts.sqlite');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
      'incomplete drafts survive a database restart with full comparison context',
      () async {
    final planning = PlanningContext(
        start: DateTime.utc(2030),
        end: DateTime.utc(2030, 1, 1, 1),
        participantIds: const ['alice'],
        sourceSlotId: 'slot',
        comparisonId: 'comparison',
        comparisonEvidenceId: 'evidence',
        expiresAt: DateTime.utc(2029, 12, 31));
    final record = await store().save(ActivityDraft(
        groupId: '',
        title: '',
        planning: planning,
        comparison: const CreationComparison(
            comparisonEvidenceId: 'other', participantIds: ['alice']),
        location: 'Campus',
        locationDetails: const ActivityLocation(
            latitude: 4.6, longitude: -74, label: 'Campus')));
    await db.close();
    db = await SqliteActivityDraftsRepository.openDatabaseForDrafts(
        factory: databaseFactoryFfi, path: '${directory.path}/drafts.sqlite');
    final loaded = (await store().load()).drafts.single;
    expect(loaded.id, record.id);
    expect(loaded.activity.title, '');
    expect(loaded.activity.locationDetails!.latitude, 4.6);
    expect(loaded.activity.planning!.comparisonEvidenceId, 'evidence');
    expect(loaded.activity.planning!.expiresAt, planning.expiresAt);
    expect(loaded.activity.comparison!.comparisonEvidenceId, 'other');
  });

  test('accounts and projects are isolated, including a previously cached list',
      () async {
    final alice = store();
    await alice.save(const ActivityDraft(groupId: '', title: 'Private'));
    await alice.load();
    account = 'bob';
    expect((await store('bob').load()).drafts, isEmpty);
    await expectLater(alice.load(), throwsA(isA<SessionFailure>()));
    account = 'alice';
    expect((await store('alice', 'different').load()).drafts, isEmpty);
  });

  test(
      'concurrent saves reject stale revisions and queue recovers after failure',
      () async {
    final repo = store();
    final initial =
        await repo.save(const ActivityDraft(groupId: '', title: 'First'));
    final saves = await Future.wait([
      repo
          .save(const ActivityDraft(groupId: '', title: 'Second'),
              previous: initial)
          .then<Object>((d) => d, onError: (Object e) => e),
      repo
          .save(const ActivityDraft(groupId: '', title: 'Stale'),
              previous: initial)
          .then<Object>((d) => d, onError: (Object e) => e),
    ]);
    expect(saves[0], isA<SavedActivityDraft>());
    expect(saves[1], isA<SessionFailure>());
    final snapshot = await repo.load();
    expect(snapshot.drafts.single.activity.title, 'Second');
    expect(snapshot.history.single.saved, 1);
    await expectLater(repo.delete(initial), throwsA(isA<SessionFailure>()));
    await repo.delete(snapshot.drafts.single);
    expect((await repo.load()).drafts, isEmpty);
    final row = (await db.query('activity_drafts')).single;
    expect(row['payload'], isNull);
  });

  test('cache avoids disk reload, mutations and explicit refresh invalidate it',
      () async {
    final repo = store();
    await repo.save(const ActivityDraft(groupId: '', title: 'Cached'));
    final snapshot = await repo.load();
    expect(identical(await repo.load(), snapshot), isTrue);
    expect(identical(await repo.load(refresh: true), snapshot), isFalse);
    await repo.save(const ActivityDraft(groupId: '', title: 'New'));
    expect((await repo.load()).drafts, hasLength(2));
  });

  test(
      'more than fifty independent drafts persist and only the selected one changes',
      () async {
    final repo = store();
    final records = <SavedActivityDraft>[];
    for (var i = 0; i < 65; i++) {
      records
          .add(await repo.save(ActivityDraft(groupId: '', title: 'Plan $i')));
    }
    expect((await repo.load()).drafts, hasLength(65));
    await repo.save(const ActivityDraft(groupId: '', title: 'Edited plan'),
        previous: records[17]);
    final reopened = (await store().load()).drafts;
    expect(reopened, hasLength(65));
    expect(reopened.singleWhere((r) => r.id == records[17].id).activity.title,
        'Edited plan');
    expect(reopened.singleWhere((r) => r.id == records[18].id).activity.title,
        'Plan 18');
  });

  testWidgets(
      'New draft preserves separate plans and selecting one resumes Details',
      (tester) async {
    final repo = UiDrafts();
    final editor = ActivityEditorViewModel(
        ManageStudySession(
            FirebaseStudySessionsRepository(FakeActivitySource())),
        drafts: repo);
    addTearDown(editor.dispose);
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: ActivityForm(viewModel: editor, onSaved: (_) {}))));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Activity name'), 'First plan');
    await tester.tap(find.text('New draft'));
    await tester.pumpAndSettle();
    expect(repo.records.single.activity.title, 'First plan');
    await tester.enterText(
        find.widgetWithText(TextField, 'Activity name'), 'Second plan');
    await tester.tap(find.text('Save as draft'));
    await tester.pumpAndSettle();
    expect(repo.records, hasLength(2));
    await tester.tap(find.text('My drafts'));
    await tester.pumpAndSettle();
    final firstCard =
        find.ancestor(of: find.text('First plan'), matching: find.byType(Card));
    final firstContinue =
        find.descendant(of: firstCard, matching: find.text('Continue'));
    await tester.ensureVisible(firstContinue);
    await tester.pumpAndSettle();
    await tester.tap(firstContinue);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'First plan'), findsOneWidget);
    expect(find.text('Back to Details'), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextField, 'Activity name'), 'First plan updated');
    await tester.tap(find.text('Save as draft'));
    await tester.pumpAndSettle();
    expect(repo.records, hasLength(2));
    expect(repo.records.map((r) => r.activity.title),
        containsAll(['First plan updated', 'Second plan']));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'system Back saves changes and closing untouched Details creates no empty draft',
      (tester) async {
    final repo = UiDrafts();
    final editor = ActivityEditorViewModel(
        ManageStudySession(
            FirebaseStudySessionsRepository(FakeActivitySource())),
        drafts: repo);
    addTearDown(editor.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => Scaffold(
                                body: ActivityForm(
                                    viewModel: editor, onSaved: (_) {})))),
                    child: const Text('Open editor'))))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Activity name'), 'Saved on exit');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Open editor'), findsOneWidget);
    expect(repo.records.single.activity.title, 'Saved on exit');
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(repo.records, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'background saves dirty Details without creating duplicate drafts',
      (tester) async {
    final repo = UiDrafts();
    final editor = ActivityEditorViewModel(
        ManageStudySession(
            FirebaseStudySessionsRepository(FakeActivitySource())),
        drafts: repo);
    addTearDown(editor.dispose);
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: ActivityForm(viewModel: editor, onSaved: (_) {}))));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Activity name'), 'Background idea');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(repo.records.single.activity.title, 'Background idea');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Activity name'), 'Updated idea');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(repo.records, hasLength(1));
    expect(repo.records.single.activity.title, 'Updated idea');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  });

  test(
      'personal history counts unique drafts, acknowledged publications and category changes',
      () async {
    final repo = store();
    for (var i = 0; i < 3; i++) {
      var record = await repo.save(
          const ActivityDraft(groupId: '', title: 'Plan', category: 'sports'));
      record = await repo.save(
          const ActivityDraft(groupId: '', title: 'Plan', category: 'study'),
          previous: record);
      await repo.published(record);
    }
    final pending =
        await repo.save(const ActivityDraft(groupId: '', title: 'Continue me'));
    final snapshot = await repo.load();
    expect(snapshot.history.single.saved, 4);
    expect(snapshot.history.single.published, 3);
    expect(snapshot.preferredCategory, 'study');
    await expectLater(repo.published(pending), completes);
    await expectLater(repo.published(pending), throwsA(isA<SessionFailure>()));
    expect((await repo.load()).history.single.published, 4);
    expect(
        const DraftsSnapshot([], [
          DraftCategoryHistory('study', 3, 2),
          DraftCategoryHistory('sports', 3, 2)
        ]).preferredCategory,
        isNull);
  });

  test(
      'failed and recovered publication keeps the same draft and records success once',
      () async {
    final repo = store();
    final source = RecoverableSource();
    final sessions =
        ManageStudySession(FirebaseStudySessionsRepository(source));
    var editor = ActivityEditorViewModel(sessions, drafts: repo);
    await editor.load();
    expect(
        await editor.saveDraft(ActivityDraft(
            groupId: 'group',
            title: 'Publish me',
            requestId: editor.publicationKey)),
        isTrue);
    expect(await editor.save(editor.localDraft!.activity), isNull);
    expect(editor.publicationUncertain, isTrue);
    expect((await repo.load()).drafts, hasLength(1));
    expect((await repo.load()).history.single.published, 0);
    editor.dispose();
    editor = ActivityEditorViewModel(sessions, drafts: repo);
    await editor.load();
    expect(editor.localDraft, isNotNull);
    expect(await editor.save(editor.recoveredDraft!), 'created-document');
    expect(source.received[0]['requestId'], source.received[1]['requestId']);
    expect((await repo.load()).drafts, isEmpty);
    expect((await repo.load()).history.single.published, 1);
    editor.dispose();
  });

  test(
      'publication validates again and local failure never sends a remote write',
      () async {
    final source = FakeActivitySource();
    final editor = ActivityEditorViewModel(
        ManageStudySession(FirebaseStudySessionsRepository(source)),
        drafts: store());
    await editor.load();
    expect(await editor.saveDraft(const ActivityDraft(groupId: '', title: '')),
        isTrue);
    expect(await editor.save(editor.localDraft!.activity), isNull);
    expect(source.writes, isEmpty);
    await store().delete(editor.localDraft!);
    expect(
        await editor
            .save(const ActivityDraft(groupId: 'group', title: 'Complete')),
        isNull);
    expect(source.writes, isEmpty);
    expect(editor.publicationUncertain, isFalse);
    editor.dispose();
  });

  test('drafts can be saved when group loading fails offline', () async {
    final editor = ActivityEditorViewModel(
        ManageStudySession(FirebaseStudySessionsRepository(OfflineGroups())),
        drafts: store());
    await editor.load();
    expect(editor.value.groups, isEmpty);
    expect(
        await editor
            .saveDraft(const ActivityDraft(groupId: '', title: 'Offline idea')),
        isTrue);
    expect((await store().load()).drafts.single.activity.title, 'Offline idea');
    editor.dispose();
  });

  test(
      'a pending database open keeps the save lock and reports failure without success',
      () async {
    final pending = Completer<Database>();
    final repo = SqliteActivityDraftsRepository(
        open: () => pending.future,
        namespace: 'project/alice',
        sessionIsCurrent: () => true);
    final editor = ActivityEditorViewModel(
        ManageStudySession(
            FirebaseStudySessionsRepository(FakeActivitySource())),
        drafts: repo);
    await editor.load();
    final first =
        editor.saveDraft(const ActivityDraft(groupId: '', title: 'Pending'));
    expect(editor.value.savingDraft, isTrue);
    expect(
        await editor
            .saveDraft(const ActivityDraft(groupId: '', title: 'Double tap')),
        isFalse);
    pending.completeError(StateError('disk failure'));
    expect(await first, isFalse);
    expect(editor.localDraft, isNull);
    expect(editor.value.error, contains('storage'));
    editor.dispose();
  });

  testWidgets('personal history changes the suggested draft on a narrow screen',
      (tester) async {
    final repo = UiDrafts()
      ..history = [
        const DraftCategoryHistory('study', 4, 3),
        const DraftCategoryHistory('sports', 5, 1)
      ];
    await repo.save(const ActivityDraft(
        groupId: '', title: 'Football', category: 'sports'));
    await repo.save(const ActivityDraft(
        groupId: '', title: 'Exam preparation', category: 'study'));
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!),
        home: ActivityDraftsView(repository: repo)));
    await tester.pumpAndSettle();
    expect(find.textContaining('most study drafts'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Suggested for you'), 150);
    expect(find.text('Exam preparation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'New Activity saves, lists, resumes and deletes an incomplete draft',
      (tester) async {
    final repo = UiDrafts();
    final editor = ActivityEditorViewModel(
        ManageStudySession(
            FirebaseStudySessionsRepository(FakeActivitySource())),
        drafts: repo);
    addTearDown(editor.dispose);
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: ActivityForm(viewModel: editor, onSaved: (_) {}))));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Activity name'), 'Study tomorrow');
    await tester.tap(find.text('Save as draft'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My drafts'));
    await tester.pumpAndSettle();
    expect(find.text('Study tomorrow'), findsOneWidget);
    expect(find.textContaining('Not enough history'), findsOneWidget);
    await tester.ensureVisible(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Study tomorrow'), findsOneWidget);
    await tester.tap(find.text('My drafts'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('No drafts yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'temporary comparison renders and survives reopening only with the same RAM cache',
      (tester) async {
    final repo = UiDrafts();
    await repo.save(const ActivityDraft(groupId: '', title: 'Study plan'));
    await repo.save(const ActivityDraft(
        groupId: '', title: 'Sport plan', category: 'sports'));
    final cache = DraftComparisonCache()
      ..leftId = '0'
      ..rightId = '1';
    Widget view(DraftComparisonCache memory) => MaterialApp(
        home: ActivityDraftsView(
            key: UniqueKey(), repository: repo, comparisons: memory));
    await tester.pumpWidget(view(cache));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare drafts'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Compare'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    expect(find.text('Different categories'), findsOneWidget);
    final result = cache.result;
    await tester.pumpWidget(view(cache));
    await tester.pumpAndSettle();
    expect(find.text('Different categories'), findsOneWidget);
    expect(cache.result, same(result));
    await tester.pumpWidget(view(DraftComparisonCache()));
    await tester.pumpAndSettle();
    expect(find.text('Different categories'), findsNothing);
    expect(repo.records, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
