import '../../features/andes_events/data/repositories/sqlite_andes_events_cache.dart';
import '../../features/andes_events/data/repositories/sqlite_saved_andes_events_repository.dart';
import '../../features/andes_events/data/repositories/firebase_andes_events_repository.dart';
import '../../features/andes_events/presentation/view_models/andes_events_view_model.dart';
import '../../features/andes_events/presentation/views/andes_events_view.dart';
import '../../core/connectivity/connectivity_service.dart';
import '../../features/schedule/data/repositories/geolocator_location_repository.dart';
import '../../features/schedule/data/repositories/local_schedule_preferences_repository.dart';
import '../../features/schedule/data/repositories/local_schedule_cache_metadata_repository.dart';
import '../../features/schedule/domain/use_cases/get_schedule_preferences.dart';
import '../../features/schedule/domain/use_cases/save_schedule_preferences.dart';
import '../../features/schedule/domain/services/distance_service.dart';
import 'package:flutter/material.dart';
import 'firebase_dependencies.dart';
import '../../features/schedule/data/repositories/firebase_schedule_repository.dart';
import '../../features/schedule/data/data_sources/google_calendar_api_data_source.dart';

import '../../features/schedule/data/adapters/google_calendar_adapter.dart';
import '../../features/schedule/data/data_sources/google_calendar_auth_data_source.dart';
import '../../features/schedule/data/data_sources/google_calendar_data_source.dart';
import '../../features/schedule/data/data_sources/mock_google_calendar_data_source.dart';
import '../../features/schedule/data/repositories/calendar_import_repository_impl.dart';
import '../../features/schedule/data/repositories/schedule_repository_impl.dart';

import '../../features/schedule/domain/repositories/calendar_import_repository.dart';
import '../../features/schedule/domain/repositories/schedule_repository.dart';
import '../../features/schedule/domain/services/availability_service.dart';
import '../../features/schedule/domain/use_cases/import_google_calendar.dart';
import '../../features/schedule/domain/use_cases/authorize_google_calendar.dart';
import '../../features/schedule/domain/use_cases/manage_schedule.dart';

import '../../features/schedule/presentation/view_models/schedule_view_model.dart';
import '../../features/schedule/presentation/views/schedule_view.dart';

class ScheduleDependencies {
  final ScheduleRepository repository;
  final CalendarImportRepository calendarImportRepository;
  final bool calendarImportEnabled;
  final FirebaseDependencies? firebase;

  const ScheduleDependencies({
    required this.repository,
    required this.calendarImportRepository,
    this.calendarImportEnabled = true,
    this.firebase,
  });

  factory ScheduleDependencies.mock() {
    final scheduleRepository = MockScheduleRepository();

    final GoogleCalendarDataSource calendarDataSource =
        MockGoogleCalendarDataSource();

    final calendarImportRepository = CalendarImportRepositoryImpl(
      dataSource: calendarDataSource,
      authDataSource: GoogleCalendarAuthDataSource(),
      adapter: const GoogleCalendarAdapter(),
    );

    return ScheduleDependencies(
      repository: scheduleRepository,
      calendarImportRepository: calendarImportRepository,
    );
  }

  factory ScheduleDependencies.firebase(FirebaseDependencies firebase) {
    final auth = GoogleCalendarAuthDataSource();
    return ScheduleDependencies(
      firebase: firebase,
      calendarImportEnabled: const bool.fromEnvironment(
        'ENABLE_GOOGLE_CALENDAR_IMPORT',
        defaultValue: true,
      ),
      repository: FirebaseScheduleRepository(
        firestore: firebase.firestore,
        auth: firebase.auth,
      ),
      calendarImportRepository: CalendarImportRepositoryImpl(
          dataSource: GoogleCalendarApiDataSource(authDataSource: auth),
          authDataSource: auth,
          adapter: const GoogleCalendarAdapter()),
    );
  }

  ScheduleViewModel createViewModel({DateTime? initialDay, String? groupId}) {
    return ScheduleViewModel(
      ManageSchedule(
        repository,
        const AvailabilityService(),
        firebase == null ? null : const GeolocatorLocationRepository(),
        const DistanceService(),
      ),
      ImportGoogleCalendar(
        calendarImportRepository,
        repository,
      ),
      getSchedulePreferences: firebase == null
          ? null
          : GetSchedulePreferences(
              LocalSchedulePreferencesRepository(auth: firebase!.auth)),
      saveSchedulePreferences: firebase == null
          ? null
          : SaveSchedulePreferences(
              LocalSchedulePreferencesRepository(auth: firebase!.auth)),
      cacheMetadataRepository: firebase == null
          ? null
          : LocalScheduleCacheMetadataRepository(auth: firebase!.auth),
      connectivityService: firebase == null ? null : ConnectivityService(),
      isOffline:
          firebase == null ? null : () => !firebase!.mobile.canAttemptRemote,
      initialDay: initialDay,
      calendarImportEnabled: calendarImportEnabled,
      authorizeGoogleCalendar:
          AuthorizeGoogleCalendar(calendarImportRepository),
    );
  }

  Stream<bool> _connectionChanges(ConnectivityService service) async* {
    yield await service.hasConnection();
    yield* service.connectionChanges;
  }

  Widget andesEventsRoute() {
    final configured = firebase;
    if (configured == null) {
      return const Scaffold(
          body: Center(child: Text('Andes Events requires Firebase.')));
    }
    final connectivity = ConnectivityService();
    return AndesEventsView(
        viewModel: AndesEventsViewModel(
            FirebaseAndesEventsRepository(
                configured.firestore, configured.auth),
            outbox: configured.scheduleOutbox,
            cache: SqliteAndesEventsCache(namespace: configured.firestore.app.options.projectId),
            connectivityChanges: _connectionChanges(connectivity),
            savedRepository: SqliteSavedAndesEventsRepository(),
            userId: configured.auth.currentUser == null
                ? null
                : '${configured.firestore.app.options.projectId}:${configured.auth.currentUser!.uid}',
            accountChanges: configured.auth.authStateChanges().map((user) =>
                user == null
                    ? null
                    : '${configured.firestore.app.options.projectId}:${user.uid}')));
  }

  Widget route(
      {String? groupId, DateTime? initialDay, Widget? activityHeader}) {
    return _ScheduleEntry(
      dependencies: this,
      groupId: groupId,
      initialDay: initialDay,
      activityHeader: activityHeader,
    );
  }
}

class _ScheduleEntry extends StatefulWidget {
  final ScheduleDependencies dependencies;
  final String? groupId;
  final DateTime? initialDay;
  final Widget? activityHeader;

  const _ScheduleEntry({
    required this.dependencies,
    this.groupId,
    this.initialDay,
    this.activityHeader,
  });

  @override
  State<_ScheduleEntry> createState() => _ScheduleEntryState();
}

class _ScheduleEntryState extends State<_ScheduleEntry> {
  late final ScheduleViewModel _viewModel;
  Set<String> _confirmedOutbox = {};

  @override
  void initState() {
    super.initState();

    _viewModel = widget.dependencies.createViewModel(
        initialDay: widget.initialDay, groupId: widget.groupId);
    final outbox = widget.dependencies.firebase?.scheduleOutbox;
    _confirmedOutbox = outbox?.operations.values.where((o) => o.status == 'confirmed').map((o) => '${o.userId}:${o.event.id}').toSet() ?? {};
    outbox?.addListener(_onOutboxChanged);
  }

  void _onOutboxChanged() {
    final outbox = widget.dependencies.firebase?.scheduleOutbox;
    if (outbox == null) return;
    final confirmed = outbox.operations.values.where((o) => o.status == 'confirmed').map((o) => '${o.userId}:${o.event.id}').toSet();
    if (confirmed.difference(_confirmedOutbox).isNotEmpty) _viewModel.refreshSchedule();
    _confirmedOutbox = confirmed;
  }

  @override
  void dispose() {
    widget.dependencies.firebase?.scheduleOutbox.removeListener(_onOutboxChanged);
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScheduleView(
      viewModel: _viewModel,
      groupId: widget.groupId,
      activityHeader: widget.activityHeader,
    );
  }
}
