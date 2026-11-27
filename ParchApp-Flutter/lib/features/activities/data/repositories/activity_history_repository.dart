import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../domain/repositories/activity_history.dart';
import '../models/activity_model.dart';

class ActivityHistoryRepository implements ActivityHistory {
  final Future<List<ActivityModel>> Function() _remote;
  final Future<Directory> Function() _directory;
  final String? Function() _userId;
  final Future<bool> Function() _isOnline;
  final BaseCacheManager _images;
  final DateTime Function() _now;

  ActivityHistoryRepository(
      {required Future<List<ActivityModel>> Function() remote,
      required Future<Directory> Function() directory,
      required String? Function() userId,
      required Future<bool> Function() isOnline,
      BaseCacheManager? images,
      DateTime Function()? now})
      : _remote = remote,
        _directory = directory,
        _userId = userId,
        _isOnline = isOnline,
        _images = images ?? DefaultCacheManager(),
        _now = now ?? DateTime.now;

  @override
  Future<HistorySnapshot> load() async {
    if (await _isOnline()) {
      try {
        return await _download();
      } catch (_) {}
    }
    final saved = await _read();
    if (saved == null) {
      throw StateError(
          'Your history is not saved on this phone yet. Connect to the internet once to download it.');
    }
    return saved;
  }

  @override
  Future<void> prefetch() async {
    try {
      if (await _isOnline()) await _download();
    } catch (_) {}
  }

  Future<HistorySnapshot> _download() async {
    final models = await _remote();
    final now = _now();
    final activities = <HistoryActivity>[];
    for (var i = 0; i < models.length; i++) {
      final activity = HistoryActivity.fromActivity(models[i].data);
      if (activity != null && activity.startsAt.isBefore(now)) {
        activities.add(activity);
      }
    }
    activities.sort((a, b) => b.startsAt.compareTo(a.startsAt));
    final snapshot =
        HistorySnapshot(List<HistoryActivity>.unmodifiable(activities), now);
    try {
      await _write(snapshot);
    } catch (_) {}
    unawaited(_saveTiles(activities));
    return snapshot;
  }

  Future<void> _saveTiles(List<HistoryActivity> activities) async {
    final tiles = <String>{};
    for (var i = 0; i < activities.length; i++) {
      final tile = activities[i].mapTile;
      if (tile != null) tiles.add(tile);
    }
    for (final tile in tiles) {
      try {
        await _images.getSingleFile(tile, headers: mapTileHeaders);
      } catch (_) {}
    }
  }

  Future<File?> _file() async {
    final uid = _userId();
    if (uid == null) return null;
    final directory = await _directory();
    return File('${directory.path}/activity_history_$uid.json');
  }

  Future<void> _write(HistorySnapshot snapshot) async {
    final file = await _file();
    if (file == null) return;
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < snapshot.activities.length; i++) {
      rows.add(snapshot.activities[i].toJson());
    }
    await file.writeAsString(
        jsonEncode(
            {'savedAt': snapshot.savedAt.toIso8601String(), 'activities': rows}),
        flush: true);
  }

  Future<HistorySnapshot?> _read() async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return null;
      final savedAt = DateTime.tryParse('${data['savedAt']}');
      final rows = data['activities'];
      if (savedAt == null || rows is! List) return null;
      final activities = <HistoryActivity>[];
      for (var i = 0; i < rows.length; i++) {
        final activity = HistoryActivity.fromJson(rows[i]);
        if (activity != null) activities.add(activity);
      }
      return HistorySnapshot(
          List<HistoryActivity>.unmodifiable(activities), savedAt,
          offline: true);
    } catch (_) {
      return null;
    }
  }
}