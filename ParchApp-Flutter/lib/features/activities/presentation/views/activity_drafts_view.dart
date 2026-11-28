import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:developer';
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
  StreamSubscription<void>? _changes;
  int _readGeneration = 0;
  late final _comparisons = widget.comparisons ?? DraftComparisonCache();
  @override
  void initState() {
    super.initState();
    _watchChanges();
    _load();
  }

  void _watchChanges() {
    final repository = widget.repository;
    if (repository is ObservableActivityDraftsRepository) {
      _changes = repository.changes.listen((_) => unawaited(_readLocal()));
    }
  }

  @override
  void didUpdateWidget(covariant ActivityDraftsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      _changes?.cancel();
      _watchChanges();
      _load();
    }
  }

  @override
  void dispose() {
    _readGeneration++;
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _readLocal({bool refresh = true}) async {
    final generation = ++_readGeneration;
    try {
      final result = await widget.repository.load(refresh: refresh);
      if (mounted && generation == _readGeneration) {
        setState(() {
          _snapshot = result;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == _readGeneration) {
        setState(() {
          _snapshot = null;
          _error = _message(e);
        });
      }
    }
  }

  Future<void> _updateInBackground(
      SyncableActivityDraftsRepository repository) async {
    try {
      await repository.synchronize();
      if (mounted && repository is! ObservableActivityDraftsRepository) {
        await _readLocal();
      }
    } catch (_) {
      // Keep saved drafts usable. App-wide coordination retries automatically.
    }
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _readLocal(refresh: refresh);
      final repository = widget.repository;
      if (repository is SyncableActivityDraftsRepository) {
        unawaited(_updateInBackground(repository));
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
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        initiallyExpanded: result != null,
        children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                        'This temporary comparison is cleared when you leave the editor or restart the app.'),
                    const SizedBox(height: 24),
                    for (final left in [true, false])
                      Padding(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: DropdownButtonFormField<String>(
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
                                  labelText:
                                      left ? 'First draft' : 'Second draft'),
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
                                      }))),
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
                      const SizedBox(height: 24),
                      Text('${result.leftTitle} ↔ ${result.rightTitle}'),
                      const SizedBox(height: 12),
                      Text(result.sameCategory
                          ? 'Same category'
                          : 'Different categories'),
                      const SizedBox(height: 8),
                      Text(result.samePlace
                          ? 'Same saved place'
                          : 'Different or unspecified places'),
                      const SizedBox(height: 8),
                      Text(
                          'Duration: ${result.leftDuration?.inMinutes.toString() ?? 'not set'} / ${result.rightDuration?.inMinutes.toString() ?? 'not set'} minutes'),
                      const SizedBox(height: 8),
                      Text(result.overlapping == null
                          ? 'Set both schedules to compare time overlap.'
                          : result.overlapping!
                              ? 'Schedules overlap'
                              : 'Schedules do not overlap'),
                    ],
                  ]))
        ]);
  }

  Widget _buildListItem(
      BuildContext context,
      int index,
      DraftsSnapshot? snapshot,
      String? preferred,
      SavedActivityDraft? recommended,
      List<SavedActivityDraft> drafts) {
    return Timeline.timeSync(
        index == 0
            ? 'activity_drafts.build_header'
            : 'activity_drafts.build_card', () {
      if (index == 0) {
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Your saved drafts',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text('Continue incomplete plans'),
              const SizedBox(height: 24),
              if (_busy) const LinearProgressIndicator(),
              if (widget.repository is ObservableActivityDraftsRepository &&
                  (widget.repository as ObservableActivityDraftsRepository)
                      .isOffline)
                const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.wifi_off_outlined, size: 18),
                          SizedBox(width: 10),
                          Expanded(
                              child: Text(
                                  'You’re offline. Drafts are saved on this device.')),
                        ])),
              if (snapshot != null) ...[
                const SizedBox(height: 16),
                Card(
                    margin: EdgeInsets.zero,
                    child: _comparisonPanel(snapshot.drafts)),
                const SizedBox(height: 24),
              ],
              if (_error != null) ...[
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                TextButton(
                    onPressed: _busy ? null : () => _load(refresh: true),
                    child: const Text('Try again'))
              ],
              if (snapshot != null)
                Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Your draft history',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 12),
                              const Text(
                                  'Unique plans saved and published from drafts, by their latest saved category.'),
                              const SizedBox(height: 12),
                              for (final h in snapshot.history)
                                Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Text(
                                        '${h.category}: ${h.saved} saved · ${h.published} published')),
                              const SizedBox(height: 12),
                              Text(preferred == null
                                  ? 'Not enough history for a suggestion. After at least 3 publications and a clear leading category, we can highlight a draft.'
                                  : recommended == null
                                      ? 'You have published the most $preferred drafts. No saved draft in that category is waiting.'
                                      : 'You have published the most $preferred drafts. Try continuing this plan.'),
                            ]))),
              if (!_busy && snapshot != null && drafts.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                        'No drafts yet. Return to New Activity and choose Save as draft.')),
              const SizedBox(height: 24),
            ]);
      }
      final record = drafts[index - 1];
      final date =
          record.updatedAt.toUtc().subtract(const Duration(hours: 5));
      return Card(
          margin: const EdgeInsets.only(bottom: 20),
          child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (record.id == recommended?.id) ...[
                      const Text('Suggested for you',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                    ],
                    Text(
                        record.activity.title.trim().isEmpty
                            ? 'Untitled activity'
                            : record.activity.title,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                        '${record.activity.category} · ${date.toIso8601String().substring(0, 16).replaceFirst('T', ' ')} · Bogotá'),
                    const SizedBox(height: 8),
                    Text(switch (record.syncStatus) {
                      'synced' => 'Saved to your account',
                      'pending' => 'Saved on this device',
                      'conflict' =>
                        'Changed on another device. Choose which version to keep.',
                      _ => 'Saved on this device',
                    }),
                    const SizedBox(height: 16),
                    if (record.syncStatus == 'conflict' &&
                        widget.repository is SyncableActivityDraftsRepository)
                      Wrap(spacing: 12, runSpacing: 12, children: [
                        TextButton(
                            onPressed:
                                _busy ? null : () => _resolve(record, false),
                            child: const Text('Use cloud version')),
                        if (record.localState == 'active')
                          TextButton(
                              onPressed:
                                  _busy ? null : () => _resolve(record, true),
                              child: const Text('Keep local as new draft')),
                      ]),
                    Wrap(spacing: 12, runSpacing: 12, children: [
                      FilledButton.tonal(
                          onPressed: _busy ||
                                  record.syncStatus == 'conflict' ||
                                  record.localState != 'active'
                              ? null
                              : () async {
                                  // Verify both account and revision before restoring.
                                  try {
                                    final fresh = await widget.repository
                                        .load(refresh: true);
                                    if (!fresh.drafts.any((d) =>
                                        d.id == record.id &&
                                        d.revision == record.revision)) {
                                      throw const SessionFailure(
                                          'This draft changed. Refresh My drafts before continuing.');
                                    }
                                    if (context.mounted) {
                                      Navigator.pop(context, record);
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      setState(() {
                                        _snapshot = null;
                                        _error = _message(e);
                                      });
                                    }
                                  }
                                },
                          child: const Text('Continue')),
                      TextButton(
                          onPressed: _busy ||
                                  record.syncStatus == 'conflict' ||
                                  record.localState != 'active'
                              ? null
                              : () => _delete(record),
                          child: const Text('Delete')),
                    ]),
                  ])));
    });
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
    // Controlled baseline for profiling eager vs on-demand card construction.
    const eagerList = bool.fromEnvironment('DRAFTS_EAGER_LIST');
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
                    child: eagerList
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var index = 0;
                                      index < drafts.length + 1;
                                      index++)
                                    _buildListItem(context, index, snapshot,
                                        preferred, recommended, drafts),
                                ]))
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                            itemCount: drafts.length + 1,
                            itemBuilder: (context, index) => _buildListItem(
                                context,
                                index,
                                snapshot,
                                preferred,
                                recommended,
                                drafts))))));
  }
}
