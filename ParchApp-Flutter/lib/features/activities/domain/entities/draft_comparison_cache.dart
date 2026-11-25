import '../repositories/activity_drafts_repository.dart';

class DraftComparison {
  final String key, leftTitle, rightTitle;
  final bool sameCategory, samePlace;
  final Duration? leftDuration, rightDuration;
  final bool? overlapping;
  const DraftComparison(
      {required this.key,
      required this.leftTitle,
      required this.rightTitle,
      required this.sameCategory,
      required this.samePlace,
      this.leftDuration,
      this.rightDuration,
      this.overlapping});
}

/// Pure, bounded, in-memory memoization. No database, files, SDK or restoration.
/// Selection/result survive returning to My drafts in this editor only.
class DraftComparisonCache {
  final _results = <String, DraftComparison>{};
  String? leftId, rightId;
  DraftComparison? result;
  String _key(SavedActivityDraft a, SavedActivityDraft b) =>
      '${a.id}:${a.revision}|${b.id}:${b.revision}|v1';

  void reconcile(List<SavedActivityDraft> records) {
    final active = records
        .where((r) => r.localState == 'active' && r.syncStatus != 'conflict')
        .toList();
    final a = active.where((r) => r.id == leftId).firstOrNull;
    final b = active.where((r) => r.id == rightId).firstOrNull;
    if (a == null) leftId = null;
    if (b == null) rightId = null;
    if (a == null || b == null || result?.key != _key(a, b)) result = null;
    final revisions = active.map((r) => '${r.id}:${r.revision}').toSet();
    _results.removeWhere((key, _) {
      final parts = key.split('|');
      return !revisions.contains(parts[0]) || !revisions.contains(parts[1]);
    });
  }

  DraftComparison compare(SavedActivityDraft a, SavedActivityDraft b) {
    if (a.id == b.id || a.localState != 'active' || b.localState != 'active') {
      throw ArgumentError('Choose two different active drafts.');
    }
    leftId = a.id;
    rightId = b.id;
    final key = _key(a, b);
    final cached = _results.remove(key);
    if (cached != null) {
      _results[key] = cached;
      return result = cached;
    }
    final left = a.activity, right = b.activity;
    final timedLeft = left.startsAt != null && left.endsAt != null;
    final timedRight = right.startsAt != null && right.endsAt != null;
    final value = DraftComparison(
        key: key,
        leftTitle: left.title.trim().isEmpty ? 'Untitled activity' : left.title,
        rightTitle:
            right.title.trim().isEmpty ? 'Untitled activity' : right.title,
        sameCategory: left.category == right.category,
        samePlace: left.location.trim().isNotEmpty &&
            left.location.trim() == right.location.trim(),
        leftDuration:
            timedLeft ? left.endsAt!.difference(left.startsAt!) : null,
        rightDuration:
            timedRight ? right.endsAt!.difference(right.startsAt!) : null,
        overlapping: timedLeft && timedRight
            ? left.startsAt!.isBefore(right.endsAt!) &&
                right.startsAt!.isBefore(left.endsAt!)
            : null);
    _results[key] = value;
    if (_results.length > 8) _results.remove(_results.keys.first);
    return result = value;
  }
}
