import 'package:flutter/material.dart';
import '../../domain/entities/study_session.dart';
import '../../domain/repositories/activity_drafts_repository.dart';
import '../../domain/entities/draft_comparison_cache.dart';

class ActivityDraftsView extends StatefulWidget {
  final ActivityDraftsRepository repository;
  final DraftComparisonCache? comparisons;
  const ActivityDraftsView(
      {super.key, required this.repository, this.comparisons});
  @override
  State<ActivityDraftsView> createState() => _ActivityDraftsViewState();
}

class _ActivityDraftsViewState extends State<ActivityDraftsView> {
  DraftsSnapshot? _snapshot;
  String? _error;
  bool _busy = false;
  late final _comparisons = widget.comparisons ?? DraftComparisonCache();
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.repository.load(refresh: refresh);
      if (mounted) setState(() => _snapshot = result);
      final repository = widget.repository;
      if (repository is SyncableActivityDraftsRepository) {
        await repository.synchronize();
        final synced = await repository.load(refresh: true);
        if (mounted) setState(() => _snapshot = synced);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _snapshot = null;
          _error = _message(e);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object e) => e is SessionFailure
      ? e.message
      : 'Unable to access saved drafts. Check device storage and try again.';

  Future<void> _delete(SavedActivityDraft draft) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Delete draft?'),
                content: const Text(
                    'The draft will be removed here and from your cloud drafts after synchronization.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Delete'))
                ]));
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.repository.delete(draft);
      if (mounted) await _load(refresh: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _message(e);
          _busy = false;
        });
      }
    }
  }

  Future<void> _resolve(SavedActivityDraft draft, bool keepLocal) async {
    setState(() => _busy = true);
    try {
      await (widget.repository as SyncableActivityDraftsRepository)
          .resolveConflict(draft, keepLocalCopy: keepLocal);
      if (mounted) await _load(refresh: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _message(e);
        });
      }
    }
  }

  Widget _comparisonPanel(List<SavedActivityDraft> records) {
    _comparisons.reconcile(records);
    final active = records
        .where((r) => r.localState == 'active' && r.syncStatus != 'conflict')
        .toList();
    final result = _comparisons.result;
    return ExpansionTile(
        title: const Text('Compare drafts'),
        initiallyExpanded: result != null,
        children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                        'This temporary comparison is cleared when you leave the editor or restart the app.'),
                    for (final left in [true, false])
                      DropdownButtonFormField<String>(
                          key: ValueKey(
                              '${left ? 'left' : 'right'}-${_comparisons.leftId}-${_comparisons.rightId}'),
                          initialValue: active.any((r) =>
                                  r.id ==
                                  (left
                                      ? _comparisons.leftId
                                      : _comparisons.rightId))
                              ? (left
                                  ? _comparisons.leftId
                                  : _comparisons.rightId)
                              : null,
                          isExpanded: true,
                          decoration: InputDecoration(
                              labelText: left ? 'First draft' : 'Second draft'),
                          items: [
                            for (final r in active)
                              DropdownMenuItem(
                                  value: r.id,
                                  child: Text(
                                      r.activity.title.trim().isEmpty
                                          ? 'Untitled activity'
                                          : r.activity.title,
                                      overflow: TextOverflow.ellipsis))
                          ],
                          onChanged: _busy
                              ? null
                              : (id) => setState(() {
                                    if (left) {
                                      _comparisons.leftId = id;
                                    } else {
                                      _comparisons.rightId = id;
                                    }
                                    _comparisons.result = null;
                                  })),
                    TextButton(
                        onPressed: _busy ||
                                _comparisons.leftId == null ||
                                _comparisons.rightId == null ||
                                _comparisons.leftId == _comparisons.rightId
                            ? null
                            : () => setState(() {
                                  _comparisons.compare(
                                      active.singleWhere(
                                          (r) => r.id == _comparisons.leftId),
                                      active.singleWhere(
                                          (r) => r.id == _comparisons.rightId));
                                }),
                        child: const Text('Compare')),
                    if (result != null) ...[
                      Text('${result.leftTitle} ↔ ${result.rightTitle}'),
                      Text(result.sameCategory
                          ? 'Same category'
                          : 'Different categories'),
                      Text(result.samePlace
                          ? 'Same saved place'
                          : 'Different or unspecified places'),
                      Text(
                          'Duration: ${result.leftDuration?.inMinutes.toString() ?? 'not set'} / ${result.rightDuration?.inMinutes.toString() ?? 'not set'} minutes'),
                      Text(result.overlapping == null
                          ? 'Set both schedules to compare time overlap.'
                          : result.overlapping!
                              ? 'Schedules overlap'
                              : 'Schedules do not overlap'),
                    ],
                  ]))
        ]);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final preferred = snapshot?.preferredCategory;
    final recommended = preferred == null
        ? null
        : snapshot!.drafts
            .where((d) =>
                d.activity.category == preferred &&
                d.localState == 'active' &&
                d.syncStatus != 'conflict')
            .firstOrNull;
    final drafts = snapshot == null
        ? <SavedActivityDraft>[]
        : [
            if (recommended != null) recommended,
            ...snapshot.drafts.where((d) => d.id != recommended?.id),
          ];
    return Scaffold(
        appBar: AppBar(title: const Text('My drafts'), actions: [
          IconButton(
              tooltip: 'Refresh drafts',
              onPressed: _busy ? null : () => _load(refresh: true),
              icon: const Icon(Icons.refresh))
        ]),
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: ListView.builder(
                        padding: const EdgeInsets.all(20),
                        itemCount: drafts.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text('Your saved drafts',
                                      style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 8),
                                  const Text(
                                      'Continue incomplete plans offline. Saved drafts sync to your private account when connected. Publishing needs a connection.'),
                                  const SizedBox(height: 16),
                                  if (_busy) const LinearProgressIndicator(),
                                  if (snapshot?.syncNotice != null)
                                    Text(snapshot!.syncNotice!),
                                  if (widget.repository
                                      is SyncableActivityDraftsRepository)
                                    TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _load(refresh: true),
                                        child: const Text('Sync drafts')),
                                  if (snapshot != null)
                                    _comparisonPanel(snapshot.drafts),
                                  if (_error != null) ...[
                                    Text(_error!,
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error)),
                                    TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _load(refresh: true),
                                        child: const Text('Try again'))
                                  ],
                                  if (snapshot != null)
                                    Card(
                                        child: Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  const Text(
                                                      'Your draft history',
                                                      style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  const Text(
                                                      'Unique plans saved and published from drafts, by their latest saved category.'),
                                                  for (final h
                                                      in snapshot.history)
                                                    Text(
                                                        '${h.category}: ${h.saved} saved · ${h.published} published'),
                                                  const SizedBox(height: 8),
                                                  Text(preferred == null
                                                      ? 'Not enough history for a suggestion. After at least 3 publications and a clear leading category, we can highlight a draft.'
                                                      : recommended == null
                                                          ? 'You have published the most $preferred drafts. No saved draft in that category is waiting.'
                                                          : 'You have published the most $preferred drafts. Try continuing this plan.'),
                                                ]))),
                                  if (!_busy &&
                                      snapshot != null &&
                                      drafts.isEmpty)
                                    const Padding(
                                        padding:
                                            EdgeInsets.symmetric(vertical: 32),
                                        child: Text(
                                            'No drafts yet. Return to New Activity and choose Save as draft.')),
                                  const SizedBox(height: 12),
                                ]);
                          }
                          final record = drafts[index - 1];
                          final date = record.updatedAt
                              .toUtc()
                              .subtract(const Duration(hours: 5));
                          return Card(
                              child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (record.id == recommended?.id)
                                          const Text('Suggested for you',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                        Text(
                                            record.activity.title.trim().isEmpty
                                                ? 'Untitled activity'
                                                : record.activity.title,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        Text(
                                            '${record.activity.category} · ${date.toIso8601String().substring(0, 16).replaceFirst('T', ' ')} · Bogotá'),
                                        Text(switch (record.syncStatus) {
                                          'synced' =>
                                            'Saved in your cloud account',
                                          'pending' =>
                                            'Saved here · cloud sync pending',
                                          'conflict' =>
                                            'Changed on another device. Choose which version to keep.',
                                          _ => 'Saved on this device',
                                        }),
                                        if (record.syncStatus == 'conflict' &&
                                            widget.repository
                                                is SyncableActivityDraftsRepository)
                                          Wrap(children: [
                                            TextButton(
                                                onPressed: _busy
                                                    ? null
                                                    : () =>
                                                        _resolve(record, false),
                                                child: const Text(
                                                    'Use cloud version')),
                                            if (record.localState == 'active')
                                              TextButton(
                                                  onPressed: _busy
                                                      ? null
                                                      : () => _resolve(
                                                          record, true),
                                                  child: const Text(
                                                      'Keep local as new draft')),
                                          ]),
                                        Wrap(spacing: 8, children: [
                                          FilledButton.tonal(
                                              onPressed: _busy ||
                                                      record.syncStatus ==
                                                          'conflict' ||
                                                      record.localState !=
                                                          'active'
                                                  ? null
                                                  : () async {
                                                      // Verify both account and revision before restoring.
                                                      try {
                                                        final fresh =
                                                            await widget
                                                                .repository
                                                                .load(
                                                                    refresh:
                                                                        true);
                                                        if (!fresh.drafts.any((d) =>
                                                            d.id == record.id &&
                                                            d.revision ==
                                                                record
                                                                    .revision)) {
                                                          throw const SessionFailure(
                                                              'This draft changed. Refresh My drafts before continuing.');
                                                        }
                                                        if (context.mounted) {
                                                          Navigator.pop(
                                                              context, record);
                                                        }
                                                      } catch (e) {
                                                        if (mounted) {
                                                          setState(() {
                                                            _snapshot = null;
                                                            _error =
                                                                _message(e);
                                                          });
                                                        }
                                                      }
                                                    },
                                              child: const Text('Continue')),
                                          TextButton(
                                              onPressed: _busy ||
                                                      record.syncStatus ==
                                                          'conflict' ||
                                                      record.localState !=
                                                          'active'
                                                  ? null
                                                  : () => _delete(record),
                                              child: const Text('Delete')),
                                        ]),
                                      ])));
                        })))));
  }
}
