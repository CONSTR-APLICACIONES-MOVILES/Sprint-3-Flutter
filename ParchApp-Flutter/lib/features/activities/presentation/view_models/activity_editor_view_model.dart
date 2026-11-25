import 'dart:math';
import 'dart:async';
import '../../domain/entities/planning_context.dart';
import 'package:flutter/foundation.dart';
import '../../domain/entities/activity_draft.dart';
import '../../domain/entities/study_session.dart';
import '../../domain/use_cases/manage_study_session.dart';
import '../../domain/repositories/places_source.dart';
import '../../domain/repositories/activity_drafts_repository.dart';

class ActivityEditorState {
  final bool loading, saving, savingDraft;
  final List<ActivityGroup> groups;
  final String? error;
  const ActivityEditorState(
      {this.loading = false,
      this.saving = false,
      this.savingDraft = false,
      this.groups = const [],
      this.error});
}

class ActivityEditorViewModel extends ValueNotifier<ActivityEditorState> {
  final PlacesSource? places;
  final ManageStudySession _sessions;
  final StudySession? session;
  final String requestedDate, requestedTime;
  final String? requestedGroupId;
  bool _disposed = false;
  String? _savedId;
  String publicationKey = List.generate(24,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
  ActivityDraft? _attempt;
  ActivityDraft? recoveredDraft;
  final ActivityDraftsRepository? drafts;
  SavedActivityDraft? localDraft;
  String? draftNotice;
  bool publicationUncertain = false;
  PlanningContext? planning;
  CreationComparison? comparison;

  bool review(ActivityDraft draft) {
    try {
      draft.validated();
      if (session == null &&
          !publicationUncertain &&
          !value.groups.any((g) => g.id == draft.groupId)) {
        throw const SessionFailure(
            'Selected group is unavailable. Refresh your groups before reviewing.');
      }
      return true;
    } on SessionFailure catch (error) {
      _emit(ActivityEditorState(groups: value.groups, error: error.message));
      return false;
    }
  }

  ActivityEditorViewModel(this._sessions,
      {this.session,
      this.drafts,
      this.places,
      this.requestedDate = '',
      this.requestedTime = '',
      this.planning,
      this.comparison,
      this.requestedGroupId})
      : super(const ActivityEditorState());

  void _emit(ActivityEditorState state) {
    if (!_disposed) value = state;
  }

  Future<void> load() async {
    if (_disposed ||
        value.loading ||
        value.saving ||
        value.savingDraft ||
        session != null) {
      return;
    }
    final previousGroups = value.groups;
    _emit(ActivityEditorState(loading: true, groups: previousGroups));
    try {
      recoveredDraft ??= await _sessions.pendingPublication();
      if (recoveredDraft != null) {
        planning = recoveredDraft!.planning;
        comparison = recoveredDraft!.comparison;
        publicationKey = recoveredDraft!.requestId!;
        _attempt = recoveredDraft;
        publicationUncertain = true;
        // Reattach an interrupted publication to its local draft, so a retry
        // can complete its lifecycle without counting a second publication.
        try {
          final snapshot = await drafts?.load();
          localDraft = snapshot?.drafts
              .where((d) => d.activity.requestId == publicationKey)
              .firstOrNull;
        } catch (_) {
          draftNotice =
              'Saved drafts could not be loaded. Retry publication before opening another draft.';
        }
      }
      _emit(ActivityEditorState(
          groups: await _sessions
              .listGroups()
              .timeout(const Duration(seconds: 6))));
    } catch (error) {
      _emit(ActivityEditorState(
          groups: previousGroups,
          error: error is SessionFailure
              ? error.message
              : 'Unable to load your groups. Try again.'));
    }
  }

  Future<bool> saveDraft(ActivityDraft draft) async {
    if (_disposed ||
        drafts == null ||
        session != null ||
        value.saving ||
        value.loading ||
        value.savingDraft ||
        publicationUncertain) {
      return false;
    }
    final groups = value.groups;
    _emit(ActivityEditorState(groups: groups, savingDraft: true));
    try {
      localDraft = await drafts!.save(draft, previous: localDraft);
      draftNotice =
          'Draft saved on this device. You can continue it from My drafts.';
      _emit(ActivityEditorState(groups: groups));
      return true;
    } catch (e) {
      _emit(ActivityEditorState(
          groups: groups,
          error: e is SessionFailure
              ? e.message
              : 'Unable to save this draft. Check device storage and try again.'));
      return false;
    }
  }

  bool resumeDraft(SavedActivityDraft record) {
    if (_disposed ||
        value.saving ||
        value.savingDraft ||
        value.loading ||
        publicationUncertain) {
      return false;
    }
    localDraft = record;
    planning = record.activity.planning;
    comparison = record.activity.comparison;
    publicationKey = record.activity.requestId ??
        List.generate(
            24,
            (_) => Random.secure()
                .nextInt(256)
                .toRadixString(16)
                .padLeft(2, '0')).join();
    _attempt = null;
    _savedId = null;
    draftNotice =
        'Draft restored. Check the group and schedule before publishing.';
    _emit(ActivityEditorState(groups: value.groups));
    return true;
  }

  bool startNewDraft() {
    if (_disposed ||
        session != null ||
        value.loading ||
        value.saving ||
        value.savingDraft ||
        publicationUncertain) {
      return false;
    }
    localDraft = null;
    recoveredDraft = null;
    planning = null;
    comparison = null;
    _attempt = null;
    _savedId = null;
    publicationKey = List.generate(
            24,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    draftNotice = 'New draft. Your other drafts are available in My drafts.';
    _emit(ActivityEditorState(groups: value.groups));
    return true;
  }

  Future<String?> save(ActivityDraft draft) async {
    if (_disposed || value.loading || value.saving || value.savingDraft) {
      return null;
    }
    if (_savedId != null) return _savedId;
    final groups = value.groups;
    _emit(ActivityEditorState(saving: true, groups: groups));
    try {
      if (session == null) {
        if (!publicationUncertain &&
            !groups.any((group) => group.id == draft.groupId)) {
          throw const SessionFailure('Choose one of your groups.');
        }
        final reviewed = publicationUncertain ? _attempt! : draft.validated();
        _attempt = reviewed;
        final input = ActivityDraft(
            groupId: reviewed.groupId,
            title: reviewed.title,
            description: reviewed.description,
            category: reviewed.category,
            location: reviewed.location,
            locationDetails: reviewed.locationDetails,
            status: reviewed.status,
            date: reviewed.date,
            time: reviewed.time,
            startsAt: reviewed.startsAt,
            endsAt: reviewed.endsAt,
            planning: reviewed.planning,
            comparison: reviewed.comparison,
            measurementVersion: reviewed.measurementVersion,
            requestId: publicationKey);
        // Persist the exact publication key before sending. A lost response
        // must be retried with this key, including after an app restart.
        if (localDraft != null && drafts != null && !publicationUncertain) {
          try {
            localDraft = await drafts!.save(input, previous: localDraft);
          } catch (e) {
            _attempt = null;
            throw SessionFailure(
                e is SessionFailure
                    ? e.message
                    : 'Unable to persist this draft. No publication was sent.',
                code: 'local-storage');
          }
        }
        _savedId = await _sessions.createActivity(input);
        publicationUncertain = false;
        final publishedDraft = localDraft;
        if (publishedDraft != null && drafts != null) {
          try {
            await drafts!.published(publishedDraft);
            localDraft = null;
          } catch (_) {
            // Server success remains success. Retrying this draft uses the
            // same key and cannot create a duplicate server activity.
            draftNotice =
                'Activity created, but the local draft could not be cleared. Reopen My drafts to retry or delete it.';
          }
        }
      } else {
        _savedId = (await _sessions.updateDetails(session!.id, draft,
                expectedVersion: session!.version))
            .id;
      }
      _emit(ActivityEditorState(groups: groups));
      return _savedId;
    } catch (error) {
      publicationUncertain = session == null &&
          _attempt != null &&
          (error is! SessionFailure ||
              [
                'unavailable',
                'deadline-exceeded',
                'network-request-failed',
                'internal',
                'unknown',
                'cancelled'
              ].contains(error.code));
      if (!publicationUncertain) recoveredDraft = null;
      _emit(ActivityEditorState(
          groups: groups,
          error: error is SessionFailure
              ? error.message
              : 'Unable to save the activity. Please try again.'));
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
