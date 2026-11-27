import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../domain/repositories/activity_history.dart';
import '../view_models/activity_history_view_model.dart';

class ActivityHistoryView extends StatefulWidget {
  final ActivityHistory repository;
  const ActivityHistoryView({super.key, required this.repository});

  @override
  State<ActivityHistoryView> createState() => _ActivityHistoryViewState();
}

class _ActivityHistoryViewState extends State<ActivityHistoryView> {
  late final ActivityHistoryViewModel _viewModel =
      ActivityHistoryViewModel(widget.repository)..load();

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Activity history')),
      body: ValueListenableBuilder<ActivityHistoryState>(
          valueListenable: _viewModel,
          builder: (context, state, _) {
            final snapshot = state.snapshot;
            if (snapshot == null) {
              if (state.loading) {
                return const Center(child: CircularProgressIndicator());
              }
              return _Message(
                  text: state.error ?? 'No history yet.',
                  onRetry: _viewModel.load);
            }
            final activities = snapshot.activities;
            return RefreshIndicator(
                onRefresh: _viewModel.load,
                child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: activities.length + 1,
                    itemBuilder: (context, index) => index == 0
                        ? _Header(
                            snapshot: snapshot,
                            stats: state.stats,
                            error: state.error)
                        : _HistoryTile(activity: activities[index - 1])));
          }));
}

String _date(DateTime value) {
  final local = value.toLocal();
  final minutes = local.minute < 10 ? '0${local.minute}' : '${local.minute}';
  return '${local.day}/${local.month}/${local.year} ${local.hour}:$minutes';
}

const _card = BoxDecoration(
    color: AppColors.surface,
    borderRadius: BorderRadius.all(Radius.circular(16)),
    border: Border.fromBorderSide(BorderSide(color: AppColors.outlineSoft)));

const _offlineCard = BoxDecoration(
    color: AppColors.blueTint,
    borderRadius: BorderRadius.all(Radius.circular(12)));

const _titleStyle = TextStyle(
    color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700);

const _detailStyle = TextStyle(color: AppColors.textSecondary, fontSize: 12.5);

class _Header extends StatelessWidget {
  final HistorySnapshot snapshot;
  final HistoryStats? stats;
  final String? error;
  const _Header({required this.snapshot, this.stats, this.error});

  @override
  Widget build(BuildContext context) {
    final summary = stats;
    return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (snapshot.offline)
            Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: _offlineCard,
                child: Row(children: [
                  const Icon(Icons.cloud_off_outlined,
                      color: AppColors.primary, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(
                          'You are offline. This history was saved on this phone on ${_date(snapshot.savedAt)}.',
                          style: _detailStyle)),
                ])),
          if (error != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(error!,
                    style: const TextStyle(color: AppColors.error))),
          Container(
              padding: const EdgeInsets.all(16),
              decoration: _card,
              child: summary == null
                  ? const Row(children: [
                      SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text('Calculating your summary...', style: _detailStyle),
                    ])
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                          Row(children: [
                            _Stat(value: summary.total, label: 'Activities'),
                            _Stat(value: summary.confirmed, label: 'Confirmed'),
                            _Stat(value: summary.thisMonth, label: 'This month'),
                          ]),
                          if (summary.total > 0) ...[
                            const SizedBox(height: 12),
                            Text(
                                summary.favoritePlace.isEmpty
                                    ? 'You meet most in the ${summary.favoriteTime.toLowerCase()}.'
                                    : 'You meet most in the ${summary.favoriteTime.toLowerCase()} at ${summary.favoritePlace}.',
                                style: _detailStyle),
                          ],
                        ])),
          if (snapshot.activities.isEmpty)
            const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text('You have no past activities yet.',
                    textAlign: TextAlign.center, style: _detailStyle)),
        ]));
  }
}

class _Stat extends StatelessWidget {
  final int value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) => Expanded(
      child: Column(children: [
        Text('$value',
            style: const TextStyle(
                color: AppColors.primary,
                fontSize: 22,
                fontWeight: FontWeight.w800)),
        Text(label, style: _detailStyle),
      ]));
}

class _HistoryTile extends StatelessWidget {
  final HistoryActivity activity;
  const _HistoryTile({required this.activity});

  @override
  Widget build(BuildContext context) {
    final tile = activity.mapTile;
    return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: _card,
        child: Row(children: [
          ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(12)),
              child: SizedBox(
                  width: 56,
                  height: 56,
                  child: tile == null
                      ? const _MapPlaceholder()
                      : CachedNetworkImage(
                          imageUrl: tile,
                          httpHeaders: mapTileHeaders,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => const _MapPlaceholder(),
                          errorWidget: (_, __, ___) =>
                              const _MapPlaceholder()))),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(activity.title, style: _titleStyle),
                const SizedBox(height: 3),
                Text(
                    activity.place.isEmpty
                        ? _date(activity.startsAt)
                        : '${_date(activity.startsAt)} · ${activity.place}',
                    style: _detailStyle),
                const SizedBox(height: 3),
                Text('${activity.people} people', style: _detailStyle),
              ])),
          Text(activity.confirmed ? 'Confirmed' : 'Proposed',
              style: TextStyle(
                  color: activity.confirmed
                      ? AppColors.success
                      : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ]));
  }
}

class _MapPlaceholder extends StatelessWidget {
  const _MapPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
      color: AppColors.blueTint,
      child: Icon(Icons.place_outlined, color: AppColors.primary));
}

class _Message extends StatelessWidget {
  final String text;
  final Future<void> Function() onRetry;
  const _Message({required this.text, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.history, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: _detailStyle),
            const SizedBox(height: 12),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ])));
}