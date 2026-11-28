import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../core/connectivity/connectivity_service.dart';
import '../data/help_repository.dart';
import '../domain/help_faq.dart';

class HelpViewModel extends ChangeNotifier {
  final Future<HelpRepository> Function() open;
  final ConnectivityService connectivity;
  HelpRepository? repository;
  StreamSubscription<bool>? _subscription;
  Timer? _debounce;
  int _queryVersion = 0;
  bool _disposed = false;
  bool loading = true, offline = false;
  String query = '';
  String? error;
  List<HelpFaq> rows = [];
  DateTime? lastSync;
  HelpViewModel({required this.open, ConnectivityService? connectivity}) : connectivity = connectivity ?? ConnectivityService();
  Future<void> load() async {
    try {
      final repo = await open();
      if (_disposed) return;
      repository = repo;
      rows = await repo.all(); lastSync = repo.lastSync; loading = false; _notify();
      try { offline = !await connectivity.hasConnection(); } catch (_) {}
      _notify();
      _subscription = connectivity.connectionChanges.listen((connected) { offline = !connected; _notify(); if (connected) refresh(); });
      unawaited(refresh());
    } catch (_) { loading = false; error = 'Could not load the help. Try again.'; _notify(); }
  }
  void search(String text) {
    query = text; _queryVersion++; final version = _queryVersion;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final result = await (query.trim().isEmpty ? repository!.all() : repository!.search(text));
        if (_disposed || version != _queryVersion) return;
        rows = result; error = null; _notify();
      } catch (_) { if (!_disposed && version == _queryVersion) { error = 'Could not load the help. Try again.'; _notify(); } }
    });
  }
  Future<void> refresh() async {
    final repo = repository; if (repo == null) return;
    if (await repo.refresh() && !_disposed) {
      final version = ++_queryVersion;
      final result = query.trim().isEmpty ? await repo.all() : await repo.search(query);
      if (!_disposed && version == _queryVersion) { rows = result; lastSync = repo.lastSync; _notify(); }
    }
  }
  void _notify() { if (!_disposed) notifyListeners(); }
  @override void dispose() { _disposed = true; _queryVersion++; _debounce?.cancel(); _subscription?.cancel(); super.dispose(); }
}
