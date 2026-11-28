import 'dart:async';

import 'package:flutter/material.dart';

import '../view_models/schedule_state.dart';

/// Persistent while offline; briefly confirms a successful reconnection.
class ScheduleLastUpdatedBanner extends StatefulWidget {
  final ScheduleState state;
  final VoidCallback onRefresh;

  const ScheduleLastUpdatedBanner({
    super.key,
    required this.state,
    required this.onRefresh,
  });

  @override
  State<ScheduleLastUpdatedBanner> createState() =>
      _ScheduleLastUpdatedBannerState();
}

class _ScheduleLastUpdatedBannerState
    extends State<ScheduleLastUpdatedBanner> {
  static const Duration _confirmationDuration = Duration(seconds: 5);

  Timer? _hideTimer;
  bool _showUpdatedConfirmation = false;

  bool get _offline =>
      widget.state.connectivityStatus == ScheduleConnectivityStatus.cached ||
      widget.state.connectivityStatus ==
          ScheduleConnectivityStatus.offlineNoCache;

  @override
  void didUpdateWidget(covariant ScheduleLastUpdatedBanner oldWidget) {
    super.didUpdateWidget(oldWidget);

    final wasOffline =
        oldWidget.state.connectivityStatus == ScheduleConnectivityStatus.cached ||
        oldWidget.state.connectivityStatus ==
            ScheduleConnectivityStatus.offlineNoCache;
    final nowOnline =
        widget.state.connectivityStatus == ScheduleConnectivityStatus.online;

    if (_offline) {
      _hideTimer?.cancel();
      _showUpdatedConfirmation = false;
      return;
    }

    // Show success only after leaving offline mode AND successfully
    // loading the current schedule. An online initial launch is silent.
    if (wasOffline &&
        nowOnline &&
        widget.state.status == ScheduleLoadStatus.ready) {
      _showUpdatedConfirmation = true;
      _hideTimer?.cancel();
      _hideTimer = Timer(_confirmationDuration, () {
        if (!mounted) return;
        setState(() => _showUpdatedConfirmation = false);
      });
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_offline && !_showUpdatedConfirmation) {
      return const SizedBox.shrink();
    }

    final offline = _offline;
    final accent = offline ? const Color(0xFF946200) : const Color(0xFF176447);
    final background =
        offline ? const Color(0xFFFFF4DE) : const Color(0xFFEAF7F0);

    final updated = widget.state.scheduleLastUpdatedAt;
    final lastUpdatedText = updated == null
        ? 'Last updated: Not available'
        : 'Last updated: ${_formatDateTime(updated)}';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withOpacity(0.20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            offline ? Icons.cloud_off_outlined : Icons.check_circle_outline,
            color: accent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  offline ? 'Schedule' : 'Schedule updated',
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  lastUpdatedText,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF334155),
                  ),
                ),
              ],
            ),
          ),
          if (offline)
            IconButton(
              tooltip: 'Refresh schedule',
              icon: const Icon(Icons.refresh_rounded),
              iconSize: 20,
              color: accent,
              onPressed: widget.state.isRefreshing ||
                      widget.state.status == ScheduleLoadStatus.loading
                  ? null
                  : widget.onRefresh,
            ),
        ],
      ),
    );
  }

  static String _formatDateTime(DateTime timestamp) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final local = timestamp.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final suffix = local.hour < 12 ? 'AM' : 'PM';
    return '${months[local.month - 1]} ${local.day}, ${local.year} '
        'at $hour:$minute $suffix';
  }
}
