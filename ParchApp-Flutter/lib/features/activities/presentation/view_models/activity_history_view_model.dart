import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../domain/repositories/activity_history.dart';

class HistoryStats {
  final int total;
  final int confirmed;
  final String favoritePlace;
  final String favoriteTime;
  final int thisMonth;

  const HistoryStats(
      {required this.total,
      required this.confirmed,
      required this.favoritePlace,
      required this.favoriteTime,
      required this.thisMonth});
}

class ActivityHistoryState {
  final bool loading;
  final HistorySnapshot? snapshot;
  final HistoryStats? stats;
  final String? error;

  const ActivityHistoryState(
      {this.loading = false, this.snapshot, this.stats, this.error});
}

class HistoryStatsWorker {
  final ReceivePort _replies = ReceivePort();
  late final Stream<Object?> _messages = _replies.asBroadcastStream();
  Isolate? _isolate;
  Future<SendPort>? _ready;
  int _next = 0;

  Future<SendPort> _start() => _ready ??= _spawn();

  Future<SendPort> _spawn() async {
    _isolate = await Isolate.spawn(_run, _replies.sendPort);
    return await _messages.first as SendPort;
  }

  Future<HistoryStats> summarize(
      List<HistoryActivity> activities, DateTime now) async {
    final port = await _start();
    final id = _next++;
    final rows = <List<Object>>[];
    for (var i = 0; i < activities.length; i++) {
      final activity = activities[i];
      final local = activity.startsAt.toLocal();
      rows.add([
        local.year,
        local.month,
        local.hour,
        activity.place,
        activity.confirmed
      ]);
    }
    final reply = _messages.firstWhere((m) => m is List && m.first == id);
    port.send([id, now.year, now.month, rows]);
    final result = await reply as List;
    return HistoryStats(
        total: result[1] as int,
        confirmed: result[2] as int,
        favoritePlace: result[3] as String,
        favoriteTime: result[4] as String,
        thisMonth: result[5] as int);
  }

  void close() {
    _isolate?.kill(priority: Isolate.immediate);
    _replies.close();
  }

  static void _run(SendPort replies) {
    final commands = ReceivePort();
    replies.send(commands.sendPort);
    commands.listen((message) => replies.send(_summarize(message as List)));
  }

  static List<Object> _summarize(List request) {
    final id = request[0] as int;
    final year = request[1] as int;
    final month = request[2] as int;
    final rows = request[3] as List;
    final places = <String, int>{};
    final times = <String, int>{};
    var confirmed = 0;
    var thisMonth = 0;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i] as List;
      final hour = row[2] as int;
      final place = row[3] as String;
      if (row[4] == true) confirmed++;
      if (row[0] == year && row[1] == month) thisMonth++;
      final time = hour < 12
          ? 'Morning'
          : hour < 18
              ? 'Afternoon'
              : 'Evening';
      times[time] = (times[time] ?? 0) + 1;
      if (place.isNotEmpty) places[place] = (places[place] ?? 0) + 1;
    }
    return [id, rows.length, confirmed, _top(places), _top(times), thisMonth];
  }

  static String _top(Map<String, int> counts) {
    var best = '';
    var most = 0;
    for (final entry in counts.entries) {
      if (entry.value > most) {
        best = entry.key;
        most = entry.value;
      }
    }
    return best;
  }
}

class ActivityHistoryViewModel extends ValueNotifier<ActivityHistoryState> {
  final ActivityHistory _repository;
  final HistoryStatsWorker _worker;
  final DateTime Function() _now;
  bool _disposed = false;

  ActivityHistoryViewModel(this._repository,
      {HistoryStatsWorker? worker, DateTime Function()? now})
      : _worker = worker ?? HistoryStatsWorker(),
        _now = now ?? DateTime.now,
        super(const ActivityHistoryState(loading: true));

  Future<void> load() async {
    if (_disposed) return;
    value = ActivityHistoryState(
        loading: true, snapshot: value.snapshot, stats: value.stats);
    try {
      final snapshot = await _repository.load();
      if (_disposed) return;
      value = ActivityHistoryState(snapshot: snapshot);
      final stats = await _worker.summarize(snapshot.activities, _now());
      if (_disposed) return;
      value = ActivityHistoryState(snapshot: snapshot, stats: stats);
    } catch (error) {
      if (_disposed) return;
      value = ActivityHistoryState(
          snapshot: value.snapshot,
          stats: value.stats,
          error: error is StateError
              ? error.message
              : 'We could not load your history. Please try again.');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _worker.close();
    super.dispose();
  }
}