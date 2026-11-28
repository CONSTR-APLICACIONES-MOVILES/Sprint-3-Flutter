// Controlled profile-mode benchmark & DevTools harness for "Mis borradores".
// Runs on real SQLite (sqflite) and real widgets (ActivityDraftsView, ActivityForm)
// using an isolated SQLite file so existing user drafts are never modified.
import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sqflite/sqflite.dart';
import 'package:parchapp/features/activities/data/repositories/mock_study_sessions_repository.dart';
import 'package:parchapp/features/activities/data/repositories/sqlite_activity_drafts_repository.dart';
import 'package:parchapp/features/activities/domain/entities/activity_draft.dart';
import 'package:parchapp/features/activities/domain/entities/activity_location.dart';
import 'package:parchapp/features/activities/domain/entities/draft_comparison_cache.dart';
import 'package:parchapp/features/activities/domain/entities/planning_context.dart';
import 'package:parchapp/features/activities/domain/use_cases/manage_study_session.dart';
import 'package:parchapp/features/activities/presentation/view_models/activity_editor_view_model.dart';
import 'package:parchapp/features/activities/presentation/views/activity_drafts_view.dart';
import 'package:parchapp/features/activities/presentation/widgets/activity_form.dart';

const String _kNamespace = 'demo-parchapp/qa-profiler';
const int _kActiveDraftCount = 60;
const int _kPublishedDraftCount = 15;

ActivityDraft _buildFixtureDraft(int index) {
  const categories = ['study', 'sports', 'social', 'other'];
  final category = categories[index % categories.length];
  final baseStart = DateTime.utc(2026, 12, 1 + (index % 20), 14 + (index % 6));
  final baseEnd = baseStart.add(Duration(minutes: 60 + (index % 3) * 30));
  return ActivityDraft(
    groupId: 'demo-group',
    title: 'Sprint 4 Plan #${index.toString().padLeft(2, '0')} ($category)',
    description:
        'Controlled profiling fixture draft #$index for evaluating local SQLite snapshot caching, lazy list building, comparison memoization and fingerprint autosave skipping. Includes realistic payload metadata.',
    category: category,
    location: index % 2 == 0
        ? 'Edificio Mario Laserna ML-${500 + (index % 15)}'
        : 'Biblioteca General Ramón de Zubiría Piso ${2 + (index % 4)}',
    status: index % 4 == 0 ? 'CONFIRMED' : 'PROPOSED',
    date: '2026-12-${(1 + (index % 20)).toString().padLeft(2, '0')}',
    time: '${(14 + (index % 6)).toString().padLeft(2, '0')}:00',
    measurementVersion: 1,
    requestId: 'req-profile-${index.toString().padLeft(4, '0')}',
    locationDetails: ActivityLocation(
      latitude: 4.6015 + (index * 0.0001),
      longitude: -74.0652 - (index * 0.0001),
      label: index % 2 == 0 ? 'Mario Laserna' : 'Biblioteca General',
      placeId: 'place-uniandes-$index',
    ),
    startsAt: baseStart,
    endsAt: baseEnd,
    planning: PlanningContext(
      groupId: 'demo-group',
      start: baseStart,
      end: baseEnd,
      participantIds: const ['qa-profiler', 'peer-1', 'peer-2'],
      sourceSlotId: 'slot-$index',
      comparisonId: 'cmp-$index',
      comparisonEvidenceId: 'ev-$index',
      expiresAt: baseStart.subtract(const Duration(hours: 2)),
    ),
    comparison: CreationComparison(
      comparisonEvidenceId: 'ev-$index',
      date: '2026-12-05',
      participantIds: const ['qa-profiler', 'peer-1', 'peer-2'],
    ),
  );
}

Future<Database> _seedProfilingDatabase() async {
  final dbPath =
      '${await getDatabasesPath()}/parchapp-drafts-profiling.sqlite';
  await deleteDatabase(dbPath);
  final db = await SqliteActivityDraftsRepository.openDatabaseForDrafts(
      path: dbPath);
  final repo = SqliteActivityDraftsRepository(
    open: () async => db,
    namespace: _kNamespace,
    sessionIsCurrent: () => true,
  );
  // Seed 15 published drafts first so category history has >= 3 publications
  // and 'study' is the unique leader (8 study, 3 sports, 2 social, 2 other).
  const publishedCategories = [
    'study',
    'study',
    'study',
    'study',
    'study',
    'study',
    'study',
    'study',
    'sports',
    'sports',
    'sports',
    'social',
    'social',
    'other',
    'other',
  ];
  for (var i = 0; i < _kPublishedDraftCount; i++) {
    final draft = _buildFixtureDraft(100 + i);
    final adjusted = ActivityDraft(
      groupId: draft.groupId,
      title: 'Published history #$i',
      description: draft.description,
      category: publishedCategories[i],
      location: draft.location,
      status: draft.status,
      date: draft.date,
      time: draft.time,
      requestId: 'pub-req-$i',
    );
    final saved = await repo.save(adjusted);
    await repo.published(saved);
  }
  // Seed 60 active drafts with deterministic IDs and timestamps.
  for (var i = 0; i < _kActiveDraftCount; i++) {
    await repo.save(_buildFixtureDraft(i));
  }
  return db;
}

ScrollableState? _findVerticalScrollable(BuildContext root) {
  ScrollableState? found;
  void visit(Element element) {
    if (element is StatefulElement && element.state is ScrollableState) {
      final s = element.state as ScrollableState;
      if (s.position.axis == Axis.vertical) {
        found = s;
      }
    }
    element.visitChildren(visit);
  }

  (root as Element).visitChildren(visit);
  return found;
}

Map<String, num> _summarizeMicros(List<int> samples) {
  if (samples.isEmpty) {
    return {'count': 0, 'meanUs': 0, 'medianUs': 0, 'p95Us': 0, 'minUs': 0, 'maxUs': 0};
  }
  final sorted = [...samples]..sort();
  final sum = sorted.fold<int>(0, (a, b) => a + b);
  final mean = sum / sorted.length;
  final mid = sorted.length ~/ 2;
  final median = sorted.length.isOdd
      ? sorted[mid].toDouble()
      : (sorted[mid - 1] + sorted[mid]) / 2.0;
  final p95Index = ((sorted.length - 1) * 0.95).round();
  return {
    'count': sorted.length,
    'meanUs': double.parse(mean.toStringAsFixed(2)),
    'medianUs': double.parse(median.toStringAsFixed(2)),
    'p95Us': sorted[p95Index],
    'minUs': sorted.first,
    'maxUs': sorted.last,
    'meanMs': double.parse((mean / 1000.0).toStringAsFixed(3)),
    'medianMs': double.parse((median / 1000.0).toStringAsFixed(3)),
    'p95Ms': double.parse((sorted[p95Index] / 1000.0).toStringAsFixed(3)),
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const scenario =
      String.fromEnvironment('PROFILE_SCENARIO', defaultValue: 'opt1_snapshot');
  const bypassCache = bool.fromEnvironment('DRAFTS_BYPASS_CACHE');
  const bypassComparisonCache =
      bool.fromEnvironment('DRAFTS_BYPASS_COMPARISON_CACHE');
  const eagerList = bool.fromEnvironment('DRAFTS_EAGER_LIST');
  const bypassFingerprint = bool.fromEnvironment('DRAFTS_BYPASS_FINGERPRINT');

  final navKey = GlobalKey<NavigatorState>();
  final statusText = ValueNotifier<String>('Seeding SQLite database...');
  final resultsNotifier = ValueNotifier<Map<String, dynamic>?>({});
  var isSeeded = false;
  final startGate = Completer<void>();
  Map<String, dynamic>? completedReport;

  registerExtension('ext.parchapp.getProfileReport', (method, params) async {
    return ServiceExtensionResponse.result(jsonEncode({
      'seeded': isSeeded,
      'ready': completedReport != null,
      'report': completedReport,
    }));
  });

  registerExtension('ext.parchapp.startScenario', (method, params) async {
    if (!startGate.isCompleted) {
      startGate.complete();
    }
    return ServiceExtensionResponse.result(jsonEncode({'started': true}));
  });

  final db = await _seedProfilingDatabase();

  runApp(MaterialApp(
    navigatorKey: navKey,
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      appBar: AppBar(title: const Text('Profiling Mis Borradores')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ValueListenableBuilder<String>(
            valueListenable: statusText,
            builder: (context, status, _) => SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<Map<String, dynamic>?>(
                    valueListenable: resultsNotifier,
                    builder: (context, data, _) => SelectableText(
                      const JsonEncoder.withIndent('  ').convert(data ?? {}),
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ));

  await SchedulerBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(milliseconds: 300));
  isSeeded = true;
  statusText.value = 'Seeded 75 rows. Waiting for host clearVMTimeline...';
  // Wait up to 8 seconds for host to clearVMTimeline and trigger startScenario,
  // or auto-start if running interactively without host script.
  await startGate.future.timeout(const Duration(seconds: 8), onTimeout: () {});

  final report = <String, dynamic>{
    'scenario': scenario,
    'flags': {
      'DRAFTS_BYPASS_CACHE': bypassCache,
      'DRAFTS_BYPASS_COMPARISON_CACHE': bypassComparisonCache,
      'DRAFTS_EAGER_LIST': eagerList,
      'DRAFTS_BYPASS_FINGERPRINT': bypassFingerprint,
    },
    'dataset': {
      'namespace': _kNamespace,
      'activeDrafts': _kActiveDraftCount,
      'publishedHistoryDrafts': _kPublishedDraftCount,
      'totalRowsInSqlite': _kActiveDraftCount + _kPublishedDraftCount,
    },
  };

  if (scenario == 'opt1_snapshot') {
    statusText.value =
        'Running Opt 1 (Snapshot RAM _cache) | bypass=$bypassCache';
    final coldLoadUs = <int>[];
    final warmLoadUs = <int>[];
    var identicalHits = 0;
    var totalWarmCalls = 0;

    final outerTask = TimelineTask()..start('profile.opt1_repository_reads');
    for (var cycle = 0; cycle < 10; cycle++) {
      final repo = SqliteActivityDraftsRepository(
        open: () async => db,
        namespace: _kNamespace,
        sessionIsCurrent: () => true,
      );
      final swCold = Stopwatch()..start();
      final firstSnap = await repo.load(refresh: false);
      swCold.stop();
      coldLoadUs.add(swCold.elapsedMicroseconds);

      for (var w = 0; w < 10; w++) {
        final swWarm = Stopwatch()..start();
        final nextSnap = await repo.load(refresh: false);
        swWarm.stop();
        warmLoadUs.add(swWarm.elapsedMicroseconds);
        totalWarmCalls++;
        if (identical(firstSnap, nextSnap)) {
          identicalHits++;
        }
      }
    }
    outerTask.finish();

    // Now test 1B: Opening and reopening ActivityDraftsView 10 times with a shared repository
    final sharedRepo = SqliteActivityDraftsRepository(
      open: () async => db,
      namespace: _kNamespace,
      sessionIsCurrent: () => true,
    );
    // Warm up initial load once
    await sharedRepo.load(refresh: false);
    final reopenViewMs = <int>[];
    for (var i = 0; i < 10; i++) {
      final sw = Stopwatch()..start();
      unawaited(navKey.currentState!.push(MaterialPageRoute(
          builder: (_) => ActivityDraftsView(repository: sharedRepo))));
      await SchedulerBinding.instance.endOfFrame;
      await SchedulerBinding.instance.endOfFrame;
      sw.stop();
      reopenViewMs.add(sw.elapsedMicroseconds);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      navKey.currentState!.pop();
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    // Keep ActivityDraftsView open at the end for DevTools & screen inspection
    unawaited(navKey.currentState!.push(MaterialPageRoute(
        builder: (_) => ActivityDraftsView(repository: sharedRepo))));
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    report['coldLoad'] = _summarizeMicros(coldLoadUs);
    report['warmLoad'] = _summarizeMicros(warmLoadUs);
    report['warmLoadRawUs'] = warmLoadUs;
    report['coldLoadRawUs'] = coldLoadUs;
    report['identicalSnapshotInstances'] = '$identicalHits/$totalWarmCalls';
    report['reopenViewTwoFrames'] = _summarizeMicros(reopenViewMs);
  } else if (scenario == 'opt2_comparison') {
    statusText.value =
        'Running Opt 2 (DraftComparisonCache) | bypass=$bypassComparisonCache';
    final repo = SqliteActivityDraftsRepository(
      open: () async => db,
      namespace: _kNamespace,
      sessionIsCurrent: () => true,
    );
    final snapshot = await repo.load(refresh: false);
    final active = snapshot.drafts;
    final cache = DraftComparisonCache();

    // Measure single cold miss vs warm hits (10 cycles)
    final coldCompareUs = <int>[];
    final warmCompareUs = <int>[];
    var sameInstanceHits = 0;
    for (var i = 0; i < 10; i++) {
      final freshCache = DraftComparisonCache();
      final a = active[i];
      final b = active[i + 10];
      final swCold = Stopwatch()..start();
      final first = freshCache.compare(a, b);
      swCold.stop();
      coldCompareUs.add(swCold.elapsedMicroseconds);

      for (var w = 0; w < 10; w++) {
        final swWarm = Stopwatch()..start();
        final next = freshCache.compare(a, b);
        swWarm.stop();
        warmCompareUs.add(swWarm.elapsedMicroseconds);
        if (identical(first, next)) sameInstanceHits++;
      }
    }

    // Batch of 400 comparisons across 4 pairs (10 samples) for sub-microsecond precision
    final batch400Us = <int>[];
    final pairs = [
      [active[0], active[1]],
      [active[2], active[3]],
      [active[4], active[5]],
      [active[6], active[7]],
    ];
    // Prime cache once
    for (final p in pairs) {
      cache.compare(p[0], p[1]);
    }
    final batchTask = TimelineTask()..start('profile.opt2_comparison_batch');
    for (var s = 0; s < 10; s++) {
      final sw = Stopwatch()..start();
      for (var iter = 0; iter < 100; iter++) {
        for (final p in pairs) {
          cache.compare(p[0], p[1]);
        }
      }
      sw.stop();
      batch400Us.add(sw.elapsedMicroseconds);
    }
    batchTask.finish();

    // Open ActivityDraftsView with active comparison result expanded
    cache.compare(active[0], active[1]);
    unawaited(navKey.currentState!.push(MaterialPageRoute(
        builder: (_) =>
            ActivityDraftsView(repository: repo, comparisons: cache))));
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    report['singleColdCompare'] = _summarizeMicros(coldCompareUs);
    report['singleWarmCompare'] = _summarizeMicros(warmCompareUs);
    report['batch400Comparisons'] = _summarizeMicros(batch400Us);
    report['batch400RawUs'] = batch400Us;
    report['perCallMeanUsInBatch'] = double.parse(
        ((_summarizeMicros(batch400Us)['meanUs'] as num) / 400.0)
            .toStringAsFixed(4));
    report['identicalComparisonInstances'] = '$sameInstanceHits/100';
  } else if (scenario == 'opt3_listview') {
    statusText.value =
        'Running Opt 3 (ListView.builder vs Eager) | eager=$eagerList';
    final repo = SqliteActivityDraftsRepository(
      open: () async => db,
      namespace: _kNamespace,
      sessionIsCurrent: () => true,
    );
    await repo.load(refresh: false);

    final openFrameTimings = <FrameTiming>[];
    final scrollFrameTimings = <FrameTiming>[];
    var collectingOpen = false;
    var collectingScroll = false;

    void timingsCallback(List<FrameTiming> timings) {
      if (collectingOpen) openFrameTimings.addAll(timings);
      if (collectingScroll) scrollFrameTimings.addAll(timings);
    }

    SchedulerBinding.instance.addTimingsCallback(timingsCallback);
    final openWallUs = <int>[];

    for (var rep = 0; rep < 10; rep++) {
      collectingOpen = true;
      final task = TimelineTask()..start('profile.opt3_open_view');
      final sw = Stopwatch()..start();
      unawaited(navKey.currentState!.push(MaterialPageRoute(
          builder: (_) => ActivityDraftsView(repository: repo))));
      await SchedulerBinding.instance.endOfFrame;
      await SchedulerBinding.instance.endOfFrame;
      sw.stop();
      task.finish();
      openWallUs.add(sw.elapsedMicroseconds);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      collectingOpen = false;

      // Scroll down 1600 px over 16 steps
      final scrollable = _findVerticalScrollable(navKey.currentContext!);
      if (scrollable != null) {
        collectingScroll = true;
        final scrollTask = TimelineTask()..start('profile.opt3_scroll_list');
        for (var step = 1; step <= 16; step++) {
          scrollable.position.jumpTo(step * 100.0);
          await SchedulerBinding.instance.endOfFrame;
        }
        scrollTask.finish();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        collectingScroll = false;
      }

      if (rep < 9) {
        navKey.currentState!.pop();
        await SchedulerBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
    SchedulerBinding.instance.removeTimingsCallback(timingsCallback);

    final openBuildUs =
        openFrameTimings.map((f) => f.buildDuration.inMicroseconds).toList();
    final openRasterUs =
        openFrameTimings.map((f) => f.rasterDuration.inMicroseconds).toList();
    final openTotalUs =
        openFrameTimings.map((f) => f.totalSpan.inMicroseconds).toList();
    final scrollBuildUs =
        scrollFrameTimings.map((f) => f.buildDuration.inMicroseconds).toList();
    final scrollRasterUs =
        scrollFrameTimings.map((f) => f.rasterDuration.inMicroseconds).toList();
    final scrollTotalUs =
        scrollFrameTimings.map((f) => f.totalSpan.inMicroseconds).toList();

    report['openViewWallTime'] = _summarizeMicros(openWallUs);
    report['openViewWallRawUs'] = openWallUs;
    report['openFramesBuild'] = _summarizeMicros(openBuildUs);
    report['openFramesRaster'] = _summarizeMicros(openRasterUs);
    report['openFramesTotal'] = _summarizeMicros(openTotalUs);
    report['openJankyFramesOver16ms'] =
        openTotalUs.where((us) => us > 16670).length;
    report['openMaxBuildMs'] = openBuildUs.isEmpty
        ? 0
        : double.parse((openBuildUs.reduce((a, b) => a > b ? a : b) / 1000.0)
            .toStringAsFixed(3));
    report['scrollFramesBuild'] = _summarizeMicros(scrollBuildUs);
    report['scrollFramesRaster'] = _summarizeMicros(scrollRasterUs);
    report['scrollFramesTotal'] = _summarizeMicros(scrollTotalUs);
    report['scrollJankyFramesOver16ms'] =
        scrollTotalUs.where((us) => us > 16670).length;
  } else if (scenario == 'opt4_fingerprint') {
    statusText.value =
        'Running Opt 4 (Fingerprint Autosave Skip) | bypass=$bypassFingerprint';
    final repo = SqliteActivityDraftsRepository(
      open: () async => db,
      namespace: _kNamespace,
      sessionIsCurrent: () => true,
    );

    final cleanExitUs = <int>[];
    final backgroundCycleUs = <int>[];
    var sqliteSaveTransactions = 0;
    var spuriousDraftRowsCreated = 0;
    var cachePreservedAfterCleanExit = 0;

    for (var cycle = 0; cycle < 10; cycle++) {
      final vm = ActivityEditorViewModel(
        ManageStudySession(MockStudySessionsRepository()),
        drafts: repo,
      );
      final formKey = GlobalKey<ActivityFormState>();
      unawaited(navKey.currentState!.push(MaterialPageRoute(
          builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Edit Draft Profiling')),
                body: ActivityForm(
                  key: formKey,
                  viewModel: vm,
                  onSaved: (_) {},
                ),
              ))));
      await SchedulerBinding.instance.endOfFrame;
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Ensure _cache is warm before testing untouched lifecycle & exit
      final warmBefore = await repo.load(refresh: false);

      final taskBg = TimelineTask()..start('profile.opt4_clean_background');
      final swBg = Stopwatch()..start();
      formKey.currentState!
          .didChangeAppLifecycleState(AppLifecycleState.hidden);
      formKey.currentState!
          .didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 35));
      formKey.currentState!
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      swBg.stop();
      taskBg.finish();
      backgroundCycleUs.add(swBg.elapsedMicroseconds);

      final taskExit = TimelineTask()..start('profile.opt4_clean_exit');
      final swExit = Stopwatch()..start();
      await formKey.currentState!.requestExit();
      swExit.stop();
      taskExit.finish();
      cleanExitUs.add(swExit.elapsedMicroseconds);

      final afterSnap = await repo.load(refresh: false);
      if (identical(warmBefore, afterSnap)) {
        cachePreservedAfterCleanExit++;
      }
      final rows = await db.rawQuery(
          'SELECT COUNT(*) AS total, SUM(revision) AS revSum '
          'FROM activity_drafts WHERE namespace = ?',
          [_kNamespace]);
      final currentTotal = (rows.single['total'] as int?) ?? 0;
      final currentRevSum = (rows.single['revSum'] as int?) ?? 0;
      const expectedRows = _kActiveDraftCount + _kPublishedDraftCount;
      const expectedRevSum = _kActiveDraftCount + _kPublishedDraftCount;
      spuriousDraftRowsCreated = currentTotal - expectedRows;
      sqliteSaveTransactions = currentRevSum - expectedRevSum;

      navKey.currentState!.pop();
      await SchedulerBinding.instance.endOfFrame;
      vm.dispose();
    }

    report['cleanExitRequestExit'] = _summarizeMicros(cleanExitUs);
    report['cleanExitRawUs'] = cleanExitUs;
    report['cleanBackgroundTransition'] = _summarizeMicros(backgroundCycleUs);
    report['unnecessarySqliteSaveTransactionsAcross10CleanCycles'] =
        sqliteSaveTransactions;
    report['spuriousEmptyDraftRowsCreatedAcross10CleanCycles'] =
        spuriousDraftRowsCreated;
    report['ramCachePreservedAfterCleanCycles'] =
        '$cachePreservedAfterCleanExit/10';
  }

  final variantTag =
      (bypassCache || bypassComparisonCache || eagerList || bypassFingerprint)
          ? 'baseline'
          : 'optimized';
  report['variant'] = variantTag;

  completedReport = report;
  resultsNotifier.value = report;
  statusText.value = 'COMPLETED: $scenario ($variantTag)';
  // Print structured JSON for automated collection
  // ignore: avoid_print
  print('PROFILE_READY:$scenario:$variantTag');
}
