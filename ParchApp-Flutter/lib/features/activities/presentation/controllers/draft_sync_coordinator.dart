import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../domain/repositories/activity_drafts_repository.dart';

/// App-lifetime coordination, independent of whether the editor is on screen.
class DraftSyncCoordinator with WidgetsBindingObserver {
  final Listenable connectivity;
  final bool Function() canAttemptRemote;
  final SyncableActivityDraftsRepository? Function() currentRepository;
  final Duration retryInterval;
  Timer? _retry;
  bool _started = false, _wasAvailable = false;
  DraftSyncCoordinator(
      {required this.connectivity,
      required this.canAttemptRemote,
      required this.currentRepository,
      this.retryInterval = const Duration(seconds: 30)});

  void start() {
    if (_started) return;
    _started = true;
    _wasAvailable = canAttemptRemote();
    connectivity.addListener(_networkChanged);
    WidgetsBinding.instance.addObserver(this);
    _retry = Timer.periodic(retryInterval, (_) {
      if (canAttemptRemote()) unawaited(_run(pendingOnly: true));
    });
    unawaited(syncNow());
  }

  void _networkChanged() {
    final available = canAttemptRemote();
    if (_wasAvailable == available) return;
    _wasAvailable = available;
    // Offline calls only notify views; they never attempt a network write.
    unawaited(syncNow());
  }

  Future<void> syncNow() => _run();

  Future<void> _run({bool pendingOnly = false}) async {
    if (!_started) return;
    try {
      final repository = currentRepository();
      if (repository == null) return;
      if (pendingOnly && repository is ObservableActivityDraftsRepository) {
        await repository.retryPending();
      } else {
        await repository.synchronize();
      }
    } catch (_) {
      // No user action is required: durable operations survive for a later retry.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(syncNow());
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    _retry?.cancel();
    connectivity.removeListener(_networkChanged);
    WidgetsBinding.instance.removeObserver(this);
  }
}
