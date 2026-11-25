import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/parch_visuals.dart';
import 'package:flutter/material.dart';
import '../../domain/entities/activity_draft.dart';
import '../../domain/entities/activity_location.dart';
import '../views/location_picker_view.dart';
import '../view_models/activity_editor_view_model.dart';
import '../../domain/repositories/activity_drafts_repository.dart';
import '../views/activity_drafts_view.dart';
import '../../domain/entities/draft_comparison_cache.dart';
import 'dart:convert';
import 'dart:async';

class ActivityForm extends StatefulWidget {
  final ActivityEditorViewModel viewModel;
  final ValueChanged<String> onSaved;
  final VoidCallback? onExit;
  const ActivityForm(
      {super.key, required this.viewModel, required this.onSaved, this.onExit});
  @override
  State<ActivityForm> createState() => ActivityFormState();
}

class ActivityFormState extends State<ActivityForm>
    with WidgetsBindingObserver {
  late final _title =
      TextEditingController(text: widget.viewModel.session?.title);
  late final _description =
      TextEditingController(text: widget.viewModel.session?.description);
  late final _location =
      TextEditingController(text: widget.viewModel.session?.location);
  late ActivityLocation? _locationDetails =
      widget.viewModel.session?.locationDetails;
  late final _date = TextEditingController(
      text: widget.viewModel.session?.legacyDate ??
          widget.viewModel.requestedDate);
  late final _time = TextEditingController(
      text: widget.viewModel.session?.legacyTime ??
          widget.viewModel.requestedTime);
  late String _category = widget.viewModel.session?.category ?? 'study';
  late String _status = widget.viewModel.session?.status ?? 'PROPOSED';
  late String? _groupId =
      widget.viewModel.planning?.groupId ?? widget.viewModel.requestedGroupId;
  late DateTime? _start = widget.viewModel.planning?.start;
  late DateTime? _end = widget.viewModel.planning?.end;
  final _scroll = ScrollController();
  ActivityDraft? _review;
  String? _localError;
  bool _recovered = false;
  String? _savedFingerprint;
  int _formVersion = 0;
  bool _restoring = false, _allowExit = false, _exiting = false;
  final _comparisons = DraftComparisonCache();

  @override
  void initState() {
    super.initState();
    _savedFingerprint = _fingerprint();
    for (final controller in [_title, _description, _location, _date, _time]) {
      controller.addListener(_fieldsChanged);
    }
    WidgetsBinding.instance.addObserver(this);
    widget.viewModel.load();
  }

  void _fieldsChanged() {
    if (mounted && !_restoring && !_allowExit) setState(() {});
  }

  bool get _needsSave =>
      widget.viewModel.drafts != null &&
      widget.viewModel.session == null &&
      _savedFingerprint != _fingerprint();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final drafts = widget.viewModel.drafts;
    if (state == AppLifecycleState.resumed &&
        drafts is SyncableActivityDraftsRepository) {
      unawaited(drafts.synchronize());
    }
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        _needsSave &&
        !_exiting &&
        !widget.viewModel.publicationUncertain) {
      unawaited(_saveDraft(showNotice: false));
    }
  }

  /// Shared by the toolbar and system Back. Review returns to Details first;
  /// leaving Details waits for its local write before permitting navigation.
  Future<bool> requestExit() async {
    final model = widget.viewModel;
    if (_exiting ||
        model.value.saving ||
        model.value.savingDraft ||
        model.publicationUncertain) {
      return false;
    }
    if (_review != null) {
      setState(() => _review = null);
      return false;
    }
    _exiting = true;
    try {
      if (_needsSave && !await _saveDraft(showNotice: false)) return false;
      if (!mounted) return false;
      setState(() => _allowExit = true);
      await WidgetsBinding.instance.endOfFrame;
      return mounted;
    } finally {
      if (mounted) setState(() => _exiting = false);
    }
  }

  Future<void> _startNewDraft() async {
    if (_needsSave && !await _saveDraft()) return;
    if (!mounted) return;
    if (widget.viewModel.startNewDraft()) {
      setState(() => _restore(const ActivityDraft(groupId: '', title: '')));
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    for (final controller in [_title, _description, _location, _date, _time]) {
      controller.dispose();
    }
    super.dispose();
  }

  ActivityDraft _draft() => ActivityDraft(
      groupId: widget.viewModel.session?.groupId ??
          _groupId ??
          (widget.viewModel.value.groups.length == 1
              ? widget.viewModel.value.groups.single.id
              : ''),
      title: _title.text,
      description: _description.text,
      location: _location.text,
      locationDetails: _locationDetails,
      category: _category,
      status: _status,
      date: _date.text,
      time: _time.text,
      startsAt: _start,
      endsAt: _end,
      planning: widget.viewModel.planning,
      comparison: widget.viewModel.comparison,
      requestId: widget.viewModel.publicationKey);

  String _fingerprint() => jsonEncode({
        ..._draft().publication(widget.viewModel.publicationKey),
        // Loading a sole group is not a user edit and must not create an
        // otherwise empty automatic draft on exit.
        'groupId': _groupId ?? widget.viewModel.session?.groupId ?? ''
      });

  void _restore(ActivityDraft draft) {
    _restoring = true;
    _title.text = draft.title;
    _description.text = draft.description;
    _location.text = draft.location;
    _locationDetails = draft.locationDetails;
    _date.text = draft.date;
    _time.text = draft.time;
    _category = draft.category;
    _status = draft.status;
    _groupId = draft.groupId;
    _start = draft.startsAt;
    _end = draft.endsAt;
    _review = null;
    _localError = null;
    _formVersion++;
    _savedFingerprint = _fingerprint();
    _restoring = false;
  }

  Future<bool> _saveDraft({bool showNotice = true}) async {
    FocusScope.of(context).unfocus();
    final saved = await widget.viewModel.saveDraft(_review ?? _draft());
    if (!mounted) return false;
    if (saved) {
      setState(() => _savedFingerprint = _fingerprint());
      if (showNotice) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Draft saved on this device. Open My drafts to continue later.')));
      }
    }
    return saved;
  }

  Future<void> _openDrafts() async {
    if (_savedFingerprint != _fingerprint()) {
      final action = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('Save your current plan?'),
                  content: const Text(
                      'Opening another draft replaces the details in this form.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, 'discard'),
                        child: const Text('Continue without saving')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, 'save'),
                        child: const Text('Save draft')),
                  ]));
      if (!mounted || action == null) return;
      if (action == 'save' && !await _saveDraft()) return;
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final record = await Navigator.of(context).push<SavedActivityDraft>(
        MaterialPageRoute(
            builder: (_) => ActivityDraftsView(
                repository: widget.viewModel.drafts!,
                comparisons: _comparisons)));
    if (!mounted || record == null) return;
    if (widget.viewModel.resumeDraft(record)) {
      setState(() => _restore(record.activity));
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  Future<void> _save() async {
    final id = await widget.viewModel.save(_review ?? _draft());
    if (mounted && id != null) {
      if (widget.viewModel.draftNotice?.startsWith('Activity created,') ==
          true) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(widget.viewModel.draftNotice!)));
      }
      widget.onSaved(id);
    }
  }

  String _label(DateTime value) {
    final wall = value.toUtc().subtract(const Duration(hours: 5));
    return '${wall.year}-${wall.month.toString().padLeft(2, '0')}-${wall.day.toString().padLeft(2, '0')} '
        '${wall.hour.toString().padLeft(2, '0')}:${wall.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pick(bool start) async {
    final now = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    final current =
        (start ? _start : _end)?.toUtc().subtract(const Duration(hours: 5)) ??
            now;
    final first = DateTime(now.year, now.month, now.day);
    final date = await showDatePicker(
        context: context,
        initialDate: current.isBefore(first) ? first : current,
        firstDate: first,
        lastDate: first.add(const Duration(days: 365)));
    if (!mounted || date == null) return;
    final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: current.hour, minute: current.minute));
    if (!mounted || time == null) return;
    setState(() {
      final instant =
          DateTime.utc(date.year, date.month, date.day, time.hour, time.minute)
              .add(const Duration(hours: 5));
      if (start) {
        _start = instant;
        _end ??= instant.add(const Duration(hours: 1));
      } else {
        _end = instant;
      }
      _localError = null;
    });
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<
          ActivityEditorState>(
      valueListenable: widget.viewModel,
      builder: (context, state, _) {
        if (!_recovered && widget.viewModel.recoveredDraft != null) {
          final draft = widget.viewModel.recoveredDraft!;
          _restore(draft);
          _review = draft;
          _recovered = true;
        }
        final editing = widget.viewModel.session != null;
        final blocked = state.saving ||
            _exiting ||
            state.savingDraft ||
            state.loading ||
            widget.viewModel.publicationUncertain;
        final scheduled = widget.viewModel.session?.startsAt != null;
        final review = _review;
        return PopScope(
            canPop: _allowExit ||
                (!state.saving &&
                    !state.savingDraft &&
                    !widget.viewModel.publicationUncertain &&
                    review == null &&
                    !(widget.viewModel.drafts != null && !editing)),
            onPopInvokedWithResult: (didPop, _) async {
              if (!didPop && await requestExit() && context.mounted) {
                if (widget.onExit != null) {
                  widget.onExit!();
                } else {
                  Navigator.of(context).pop();
                }
              }
            },
            child: SingleChildScrollView(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(
                    20, 12, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          editing
                              ? 'Modify Activity Details'
                              : review == null
                                  ? 'Create New Activity'
                                  : 'Review Activity',
                          style: const TextStyle(
                              fontSize: 25,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 20),
                      if (!editing && widget.viewModel.drafts != null) ...[
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          OutlinedButton.icon(
                              onPressed: blocked ? null : _saveDraft,
                              icon: const Icon(Icons.save_outlined),
                              label: Text(state.savingDraft
                                  ? 'Saving draft…'
                                  : 'Save as draft')),
                          TextButton.icon(
                              onPressed: blocked ? null : _openDrafts,
                              icon: const Icon(Icons.drafts_outlined),
                              label: const Text('My drafts')),
                          TextButton.icon(
                              onPressed: blocked ? null : _startNewDraft,
                              icon: const Icon(Icons.add),
                              label: const Text('New draft')),
                        ]),
                        const Text(
                            'Changes are saved on this device when you leave Details. Cloud sync runs when connected.'),
                        if (widget.viewModel.draftNotice != null)
                          Text(widget.viewModel.draftNotice!),
                        const SizedBox(height: 16),
                      ],
                      if (!editing) ...[
                        Row(children: [
                          Expanded(
                              child: Row(children: [
                            CircleAvatar(
                                radius: 17,
                                backgroundColor: review == null
                                    ? AppColors.primary
                                    : AppColors.success,
                                child: review == null
                                    ? const Text('1',
                                        style: TextStyle(color: Colors.white))
                                    : const Icon(Icons.check,
                                        color: Colors.white, size: 18)),
                            const SizedBox(width: 8),
                            const Flexible(
                                child: Text('Details',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w700))),
                          ])),
                          const SizedBox(width: 24, child: Divider()),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Row(children: [
                            CircleAvatar(
                                radius: 17,
                                backgroundColor: review == null
                                    ? AppColors.blueTint
                                    : AppColors.primary,
                                child: Text('2',
                                    style: TextStyle(
                                        color: review == null
                                            ? AppColors.textSecondary
                                            : Colors.white))),
                            const SizedBox(width: 8),
                            const Flexible(
                                child: Text('Review',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w700))),
                          ])),
                        ]),
                        const SizedBox(height: 24),
                      ],
                      if (state.loading) const LinearProgressIndicator(),
                      if (!editing &&
                          !state.loading &&
                          state.groups.isEmpty) ...[
                        Text(state.error ??
                            'You need to belong to a group before creating an activity.'),
                        TextButton(
                            onPressed: state.saving || state.loading
                                ? null
                                : widget.viewModel.load,
                            child: const Text('Reload groups')),
                      ],
                      if (review != null) ...[
                        Text(review.title,
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 12),
                        Text(state.groups
                                .where((g) => g.id == review.groupId)
                                .firstOrNull
                                ?.name ??
                            'Group unavailable'),
                        Text(
                            '${review.category} · ${review.status == 'CONFIRMED' ? 'Confirmed' : 'Proposed'}'),
                        Text(review.startsAt == null
                            ? 'Not scheduled'
                            : '${_label(review.startsAt!)} → ${_label(review.endsAt!)} · America/Bogota'),
                        Text(review.location.isEmpty
                            ? 'Location not set'
                            : review.location),
                        Text(review.description),
                        const SizedBox(height: 12),
                        Text(review.planning == null
                            ? 'Invitations: members of the selected group.'
                            : 'Compared participants: ${review.planning!.participantIds.length}'),
                        for (final group in state.groups
                            .where((g) => g.id == review.groupId))
                          for (final entry in group.members.entries.where((e) =>
                              review.planning == null ||
                              review.planning!.participantIds.contains(e.key)))
                            Text(entry.value),
                        const SizedBox(height: 12),
                        const Text(
                            'Your group will receive invitations in ParchApp.'),
                        TextButton(
                            onPressed: blocked
                                ? null
                                : () {
                                    setState(() => _review = null);
                                    _scroll.jumpTo(0);
                                  },
                            child: const Text('Back to Details')),
                      ] else ...[
                        TextField(
                            controller: _title,
                            enabled: !blocked,
                            maxLength: 120,
                            decoration: const InputDecoration(
                                labelText: 'Activity name')),
                        const SizedBox(height: 16),
                        if (!editing && state.groups.isNotEmpty) ...[
                          DropdownButtonFormField<String>(
                              key: ValueKey('group-$_formVersion'),
                              initialValue: state.groups
                                      .any((g) => g.id == _groupId)
                                  ? _groupId
                                  : _groupId == null && state.groups.length == 1
                                      ? state.groups.single.id
                                      : null,
                              isExpanded: true,
                              decoration:
                                  const InputDecoration(labelText: 'Group'),
                              items: [
                                for (final g in state.groups)
                                  DropdownMenuItem(
                                      value: g.id, child: Text(g.name))
                              ],
                              onChanged: blocked ||
                                      widget.viewModel.planning?.groupId != null
                                  ? null
                                  : (v) => setState(() => _groupId = v)),
                          const SizedBox(height: 16),
                        ],
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final category in [
                            'study',
                            'sports',
                            'social',
                            'other'
                          ])
                            ChoiceChip(
                                label: Text(category),
                                selected: category == _category,
                                showCheckmark: false,
                                selectedColor: AppColors.primary,
                                shape: const StadiumBorder(),
                                labelStyle: TextStyle(
                                    color: category == _category
                                        ? Colors.white
                                        : AppColors.textPrimary),
                                onSelected: blocked
                                    ? null
                                    : (_) =>
                                        setState(() => _category = category))
                        ]),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                            key: ValueKey('status-$_formVersion'),
                            initialValue: _status,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: 'Status'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'PROPOSED', child: Text('Proposed')),
                              DropdownMenuItem(
                                  value: 'CONFIRMED', child: Text('Confirmed'))
                            ],
                            onChanged: blocked
                                ? null
                                : (v) => setState(() => _status = v!)),
                        const SizedBox(height: 16),
                        if (!editing) ...[
                          if (widget.viewModel.comparison != null)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: ParchPill(
                                    'Compared ${widget.viewModel.comparison!.participantIds.length} people · ${widget.viewModel.comparison!.date ?? ''}')),
                          const Text('Date & Time · Bogotá',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary)),
                          Text(_start == null
                              ? 'Not scheduled. You may publish a proposal without a scheduled interval.'
                              : '${_label(_start!)} → ${_end == null ? 'Choose end' : _label(_end!)}'),
                          if (widget.viewModel.planning == null) ...[
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                                onPressed: blocked ? null : () => _pick(true),
                                icon: const Icon(Icons.calendar_month_outlined,
                                    color: AppColors.primary),
                                label: Text(_start == null
                                    ? 'Choose start'
                                    : _label(_start!))),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                                onPressed: blocked ? null : () => _pick(false),
                                icon: const Icon(Icons.schedule,
                                    color: AppColors.primary),
                                label: Text(_end == null
                                    ? 'Choose end'
                                    : _label(_end!))),
                            if (_start != null)
                              TextButton(
                                  onPressed: blocked
                                      ? null
                                      : () => setState(() {
                                            _start = null;
                                            _end = null;
                                          }),
                                  child: const Text('Remove schedule')),
                          ] else
                            const Text(
                                'Selected in Schedule. Return there to change the slot or participants.'),
                        ] else if (!scheduled) ...[
                          TextField(
                              controller: _date,
                              enabled: !blocked,
                              decoration: const InputDecoration(
                                  labelText: 'Requested date (optional)')),
                          TextField(
                              controller: _time,
                              enabled: !blocked,
                              decoration: const InputDecoration(
                                  labelText: 'Requested time (optional)')),
                        ] else
                          const Text(
                              'Change the scheduled interval using recommendations in Activity Details.'),
                        const SizedBox(height: 20),
                        TextField(
                            controller: _description,
                            enabled: !blocked,
                            minLines: 2,
                            maxLines: 4,
                            maxLength: 5000,
                            decoration: const InputDecoration(
                                labelText: 'Description')),
                        const SizedBox(height: 16),
                        TextField(
                            controller: _location,
                            enabled: !blocked,
                            onChanged: (_) =>
                                setState(() => _locationDetails = null),
                            maxLength: 500,
                            decoration:
                                const InputDecoration(labelText: 'Location')),
                        OutlinedButton.icon(
                            onPressed: blocked ||
                                    widget.viewModel.places == null
                                ? null
                                : () async {
                                    final selected = await Navigator.of(context)
                                        .push<ActivityLocation>(
                                            MaterialPageRoute(
                                                builder: (_) =>
                                                    LocationPickerView(
                                                        source: widget
                                                            .viewModel.places!,
                                                        initial:
                                                            _locationDetails)));
                                    if (!mounted || selected == null) return;
                                    setState(() {
                                      _locationDetails = selected;
                                      _location.text = selected.label;
                                    });
                                  },
                            icon: const Icon(Icons.map_outlined),
                            label: Text(_locationDetails == null
                                ? 'Choose on Google Maps'
                                : 'Change map location')),
                        if (_locationDetails != null)
                          Text(
                              'Map pin saved · ${_locationDetails!.latitude.toStringAsFixed(5)}, ${_locationDetails!.longitude.toStringAsFixed(5)}'),
                        const SizedBox(height: 16),
                      ],
                      if (state.error != null)
                        Text(state.error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      if (editing && state.error != null)
                        TextButton(
                            onPressed: state.saving
                                ? null
                                : () => Navigator.of(context).pop(),
                            child:
                                const Text('Close editor and reload activity')),
                      if (_localError != null) Text(_localError!),
                      if (widget.viewModel.publicationUncertain)
                        const Text(
                            'Publication acknowledgement is pending. Retry this same publication before changing details.'),
                      const SizedBox(height: 24),
                      FilledButton(
                          onPressed: state.loading ||
                                  state.savingDraft ||
                                  state.saving ||
                                  (!editing &&
                                      state.groups.isEmpty &&
                                      !widget.viewModel.publicationUncertain)
                              ? null
                              : editing || review != null
                                  ? _save
                                  : () {
                                      FocusScope.of(context).unfocus();
                                      final draft = _draft();
                                      if (widget.viewModel.review(draft)) {
                                        setState(
                                            () => _review = draft.validated());
                                        _scroll.jumpTo(0);
                                      }
                                    },
                          child: Text(state.saving
                              ? 'Saving…'
                              : editing
                                  ? 'Save Changes'
                                  : review == null
                                      ? 'Review Activity'
                                      : 'Create Activity')),
                      if (editing)
                        TextButton(
                            onPressed: state.saving
                                ? null
                                : () => Navigator.of(context).pop(),
                            child: const Text('Dismiss')),
                    ])));
      });
}
