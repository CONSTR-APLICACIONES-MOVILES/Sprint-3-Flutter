import '../../features/andes_events/data/repositories/firebase_schedule_intent_sender.dart';
import '../../features/andes_events/data/repositories/sqlite_schedule_outbox.dart';
import '../../features/andes_events/domain/services/schedule_outbox.dart';
import '../../core/connectivity/connectivity_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/data/mobile_api.dart';
import '../../core/data/offline_mobile_api.dart';
import '../../core/data/sqlite_offline_store.dart';
import '../../core/data/restore_auth_session.dart';
import 'dart:async';
import '../../features/activities/data/data_sources/creation_attempt_monitor.dart';
import '../../features/activities/data/repositories/sqlite_activity_drafts_repository.dart';
import '../../features/activities/presentation/controllers/draft_sync_coordinator.dart';

/// Uses the checked-in live configuration or the shared demo-parchapp emulators.
class FirebaseDependencies {
  final FirebaseAuth auth;
  final FirebaseFirestore firestore;
  final FirebaseFunctions functions;
  final OfflineMobileApi mobile;
  late final ScheduleOutbox scheduleOutbox;
  final Map<String, CreationAttemptMonitor> _creationMonitors = {};
  final Map<String, SqliteActivityDraftsRepository> _draftRepositories = {};
  DraftSyncCoordinator? _draftSync;
  FirebaseDependencies._(
      this.auth, this.firestore, this.functions, this.mobile);

  SqliteActivityDraftsRepository? get activityDrafts {
    final uid = auth.currentUser?.uid;
    if (uid == null) return null;
    return _draftRepositories.putIfAbsent(
        uid,
        () => SqliteActivityDraftsRepository(
            open: SqliteActivityDraftsRepository.openDefault,
            namespace: '${auth.app.options.projectId}/$uid',
            canAttemptRemote: () => mobile.canAttemptRemote,
            sessionIsCurrent: () => auth.currentUser?.uid == uid,
            remoteCall: (name, input) =>
                FirebaseMobileApi(functions, auth: auth).call(name, {
                  ...input,
                  if (name != 'getActivityDrafts') 'clientUserId': uid,
                })));
  }

  Future<CreationAttemptMonitor> creationMonitor(String uid) async {
    final preferences = await SharedPreferences.getInstance();
    return _creationMonitors.putIfAbsent(
        uid,
        () => CreationAttemptMonitor(preferences,
            project: firestore.app.options.projectId,
            uid: uid,
            canSend: () =>
                auth.currentUser?.uid == uid && mobile.canAttemptRemote,
            send: (event) async {
              if (auth.currentUser?.uid != uid) {
                throw StateError('Session changed.');
              }
              await functions
                  .httpsCallable('recordCreationAttempt')
                  .call(event);
            }));
  }

  static Future<FirebaseDependencies> initialize() async {
    const emulators =
        bool.fromEnvironment('USE_FIREBASE_EMULATORS', defaultValue: false);
    // Platform configuration now creates a live default app on Android. Keep
    // it initialized (native Firestore needs a default delegate), and isolate
    // emulator Auth/Firestore/Functions in a separate named app.
    final defaultApp = await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform);
    final FirebaseApp app;
    if (emulators) {
      const emulatorProject = String.fromEnvironment(
          'FIREBASE_EMULATOR_PROJECT',
          defaultValue: 'demo-parchapp');
      if (!RegExp(r'^demo-[a-z0-9-]{1,40}$').hasMatch(emulatorProject)) {
        throw StateError('Emulator verification requires a demo project.');
      }
      final platform = kIsWeb
          ? 'web'
          : switch (defaultTargetPlatform) {
              TargetPlatform.android => 'android',
              TargetPlatform.iOS || TargetPlatform.macOS => 'ios',
              _ => 'web',
            };
      // Emulator-only placeholders. Android Functions validates API-key syntax
      // even locally; demoProjectId's short generated key fails that validation.
      app = await Firebase.initializeApp(
          name: emulatorProject,
          options: FirebaseOptions(
              apiKey: 'A00000000000000000000000000000000000000',
              appId: '1:1234567890:$platform:0000000000000000000000',
              messagingSenderId: '1234567890',
              projectId: emulatorProject));
    } else {
      app = defaultApp;
    }
    final auth = FirebaseAuth.instanceFor(app: app);
    final firestore = FirebaseFirestore.instanceFor(app: app);
    final functions =
        FirebaseFunctions.instanceFor(app: app, region: 'us-central1');
    if (emulators) {
      const configuredHost = String.fromEnvironment('FIREBASE_EMULATOR_HOST');
      final host = configuredHost.isNotEmpty
          ? configuredHost
          : !kIsWeb && defaultTargetPlatform == TargetPlatform.android
              ? '10.0.2.2'
              : '127.0.0.1';
      await auth.useAuthEmulator(host, 9099);
      firestore.useFirestoreEmulator(host, 8080);
      firestore.settings = const Settings(persistenceEnabled: false);
      functions.useFunctionsEmulator(host, 5001);
    }
    // Wait for any persisted account before constructing routes/catalog queries.
    await auth.authStateChanges().first;
    await validateRestoredAuthSession(auth);
    final preferences = await SharedPreferences.getInstance();
    final nativeSqlite = !kIsWeb &&
        {TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS}
            .contains(defaultTargetPlatform);
    final OfflineStore offlineStore = nativeSqlite
        ? await SqliteOfflineStore.open(legacyPreferences: preferences)
        : PreferencesOfflineStore(preferences);
    final mobile = OfflineMobileApi(
        remote: FirebaseMobileApi(functions, auth: auth),
        store: offlineStore,
        project: app.options.projectId,
        currentUserId: () => auth.currentUser?.uid);
    final dependencies =
        FirebaseDependencies._(auth, firestore, functions, mobile);
    dependencies.scheduleOutbox = ScheduleOutbox(
      SqliteScheduleOutbox(), FirebaseScheduleIntentSender(firestore, auth),
      () => auth.currentUser == null ? null : '${app.options.projectId}:${auth.currentUser!.uid}');
    final outbox = dependencies.scheduleOutbox;
    void syncOutbox() { unawaited(outbox.sync().catchError((Object _) {})); }
    final connectivity = ConnectivityService();
    connectivity.connectionChanges.listen((available) { if (available) syncOutbox(); });
    WidgetsBinding.instance.addObserver(_OutboxLifecycle(syncOutbox));
    void retryMetrics() {
      final uid = auth.currentUser?.uid;
      if (uid != null) {
        unawaited(dependencies
            .creationMonitor(uid)
            .then((monitor) => monitor.flush())
            .catchError((Object _) {}));
      }
    }

    auth.authStateChanges().listen((_) {
      mobile.refreshSession();
      syncOutbox();
      retryMetrics();
      unawaited(dependencies._draftSync?.syncNow() ?? Future<void>.value());
    });
    var wasOffline = mobile.value.offline || mobile.value.forced;
    mobile.addListener(() {
      final offline = mobile.value.offline || mobile.value.forced;
      if (wasOffline && !offline) retryMetrics();
      wasOffline = offline;
    });
    retryMetrics();
    dependencies._draftSync = DraftSyncCoordinator(
        connectivity: mobile,
        canAttemptRemote: () => mobile.canAttemptRemote,
        currentRepository: () => dependencies.activityDrafts)
      ..start();
    syncOutbox();
    return dependencies;
  }
}

class _OutboxLifecycle with WidgetsBindingObserver {
  final void Function() sync;
  _OutboxLifecycle(this.sync);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) sync();
  }
}
