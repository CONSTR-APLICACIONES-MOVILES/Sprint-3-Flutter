import '../entities/activity_draft.dart';

class SavedActivityDraft {
  final String id;
  final int revision;
  final DateTime updatedAt;
  final ActivityDraft activity;
  final String syncStatus;
  final String localState;
  const SavedActivityDraft(
      {required this.id,
      required this.revision,
      required this.updatedAt,
      required this.activity,
      this.syncStatus = 'local',
      this.localState = 'active'});
}

class DraftCategoryHistory {
  final String category;
  final int saved, published;
  const DraftCategoryHistory(this.category, this.saved, this.published);
}

class DraftsSnapshot {
  final List<SavedActivityDraft> drafts;
  final List<DraftCategoryHistory> history;
  final String? syncNotice;
  const DraftsSnapshot(this.drafts, this.history, {this.syncNotice});

  // Require at least three acknowledged publications and a unique leader.
  // This is a descriptive personal history, not a prediction of success.
  String? get preferredCategory {
    if (history.fold<int>(0, (sum, h) => sum + h.published) < 3) return null;
    final ranked = [...history]
      ..sort((a, b) => b.published.compareTo(a.published));
    if (ranked.isEmpty ||
        ranked.first.published == 0 ||
        (ranked.length > 1 && ranked[0].published == ranked[1].published)) {
      return null;
    }
    return ranked.first.category;
  }
}

abstract interface class SyncableActivityDraftsRepository
    implements ActivityDraftsRepository {
  Future<void> synchronize();
  Future<void> resolveConflict(SavedActivityDraft draft,
      {required bool keepLocalCopy});
}

abstract interface class ObservableActivityDraftsRepository
    implements SyncableActivityDraftsRepository {
  Stream<void> get changes;
  bool get isOffline;
  Future<void> retryPending();
}

abstract interface class ActivityDraftsRepository {
  Future<DraftsSnapshot> load({bool refresh = false});
  Future<SavedActivityDraft> save(ActivityDraft activity,
      {SavedActivityDraft? previous});
  Future<void> delete(SavedActivityDraft draft);
  Future<void> published(SavedActivityDraft draft);
}
