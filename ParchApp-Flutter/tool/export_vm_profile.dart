// Exports original VM Service Timeline traces and Memory metrics from a live
// Flutter --profile process into docs/profiling/mis-borradores/.
import 'dart:convert';
import 'dart:io';

Future<Map<String, dynamic>> _rpc(
    HttpClient client, Uri baseUri, String method,
    [Map<String, dynamic>? params]) async {
  final query = params == null || params.isEmpty
      ? ''
      : '?${params.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value.toString())}').join('&')}';
  final baseStr =
      baseUri.toString().endsWith('/') ? baseUri.toString() : '$baseUri/';
  final url = Uri.parse('$baseStr$method$query');
  final req = await client.getUrl(url);
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  final decoded = jsonDecode(body) as Map<String, dynamic>;
  if (decoded.containsKey('error')) {
    throw StateError('VM Service RPC error on $method: ${decoded['error']}');
  }
  return (decoded['result'] as Map<String, dynamic>?) ?? decoded;
}

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
        'Usage: dart run tool/export_vm_profile.dart <vm-service-uri> <trace-output-path> <metrics-output-path>');
    exit(64);
  }
  final vmUri = Uri.parse(args[0]);
  final tracePath = args[1];
  final metricsPath = args[2];

  final client = HttpClient();
  try {
    final vm = await _rpc(client, vmUri, 'getVM');
    final isolates = (vm['isolates'] as List?) ?? const [];
    Map<String, dynamic>? mainIsolate;
    for (final iso in isolates) {
      final map = iso as Map<String, dynamic>;
      if ((map['name'] as String?)?.contains('main') == true) {
        mainIsolate = map;
        break;
      }
    }
    mainIsolate ??=
        isolates.isNotEmpty ? isolates.first as Map<String, dynamic> : null;
    final isolateId = mainIsolate?['id'] as String?;

    Map<String, dynamic>? memoryUsage;
    Map<String, dynamic>? allocationSummary;
    if (isolateId != null) {
      memoryUsage = await _rpc(
          client, vmUri, 'getMemoryUsage', {'isolateId': isolateId});
      try {
        final alloc = await _rpc(
            client, vmUri, 'getAllocationProfile', {'isolateId': isolateId});
        final members = (alloc['members'] as List?) ?? const [];
        final nonZero = members
            .map((m) => m as Map<String, dynamic>)
            .where((m) => ((m['instancesCurrent'] as int?) ?? 0) > 0)
            .toList()
          ..sort((a, b) => ((b['bytesCurrent'] as int?) ?? 0)
              .compareTo((a['bytesCurrent'] as int?) ?? 0));
        final draftClasses = nonZero.where((m) {
          final className =
              ((m['class'] as Map?)?['name'] as String?) ?? '';
          return const {
            'SavedActivityDraft',
            'ActivityDraft',
            'DraftsSnapshot',
            'DraftCategoryHistory',
            'DraftComparison',
            'DraftComparisonCache',
            'Card',
            'ActivityDraftsView',
            'ActivityForm',
          }.contains(className);
        }).map((m) => {
              'className': (m['class'] as Map?)?['name'],
              'instancesCurrent': m['instancesCurrent'],
              'bytesCurrent': m['bytesCurrent'],
            }).toList();
        allocationSummary = {
          'memoryUsageFromProfile': alloc['memoryUsage'],
          'totalLiveClasses': nonZero.length,
          'draftFeatureClasses': draftClasses,
          'top15ClassesByBytes': nonZero.take(15).map((m) => {
                'className': (m['class'] as Map?)?['name'],
                'instancesCurrent': m['instancesCurrent'],
                'bytesCurrent': m['bytesCurrent'],
              }).toList(),
        };
      } catch (_) {}
    }

    final timeline = await _rpc(client, vmUri, 'getVMTimeline');
    final events = (timeline['traceEvents'] as List?) ?? const [];

    // Summarize custom activity_drafts.* and profile.* timeline events
    final eventCounts = <String, int>{};
    final beginTimestamps = <String, List<int>>{};
    final durationsUs = <String, List<int>>{};

    for (final raw in events) {
      final ev = raw as Map<String, dynamic>;
      final name = ev['name'] as String?;
      final ph = ev['ph'] as String?;
      if (name == null) continue;
      if (name.startsWith('activity_drafts.') ||
          name.startsWith('profile.') ||
          name == 'Frame' ||
          name == 'Animator::BeginFrame' ||
          name == 'GPURasterizer::Draw') {
        eventCounts['$name ($ph)'] = (eventCounts['$name ($ph)'] ?? 0) + 1;
        final ts = ev['ts'] as int?;
        final dur = ev['dur'] as int?;
        if (ph == 'X' && dur != null) {
          durationsUs.putIfAbsent(name, () => []).add(dur);
        } else if ((ph == 'B' || ph == 'b') && ts != null) {
          beginTimestamps.putIfAbsent(name, () => []).add(ts);
        } else if ((ph == 'E' || ph == 'e') && ts != null) {
          final starts = beginTimestamps[name];
          if (starts != null && starts.isNotEmpty) {
            final startTs = starts.removeLast();
            if (ts >= startTs) {
              durationsUs.putIfAbsent(name, () => []).add(ts - startTs);
            }
          }
        }
      }
    }

    final durationSummaries = <String, dynamic>{};
    for (final entry in durationsUs.entries) {
      final list = [...entry.value]..sort();
      if (list.isEmpty) continue;
      final sum = list.fold<int>(0, (a, b) => a + b);
      final mean = sum / list.length;
      final mid = list.length ~/ 2;
      final median = list.length.isOdd
          ? list[mid].toDouble()
          : (list[mid - 1] + list[mid]) / 2.0;
      final p95 = list[((list.length - 1) * 0.95).round()];
      durationSummaries[entry.key] = {
        'count': list.length,
        'meanUs': double.parse(mean.toStringAsFixed(2)),
        'medianUs': double.parse(median.toStringAsFixed(2)),
        'p95Us': p95,
        'minUs': list.first,
        'maxUs': list.last,
      };
    }

    final traceFile = File(tracePath);
    await traceFile.parent.create(recursive: true);
    await traceFile.writeAsString(jsonEncode({
      'traceEvents': events,
      'timeOriginMicros': timeline['timeOriginMicros'],
      'timeExtentMicros': timeline['timeExtentMicros'],
    }));

    final metricsFile = File(metricsPath);
    await metricsFile.parent.create(recursive: true);
    await metricsFile.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'capturedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'vmArchitectureBits': vm['architectureBits'],
      'vmTargetCPU': vm['targetCPU'],
      'vmHostCPU': vm['hostCPU'],
      'vmOperatingSystem': vm['operatingSystem'],
      'vmVersion': vm['version'],
      'isolateId': isolateId,
      'isolateName': mainIsolate?['name'],
      'memoryUsage': memoryUsage,
      'allocationSummary': allocationSummary,
      'timelineTotalEvents': events.length,
      'timelineTimeOriginMicros': timeline['timeOriginMicros'],
      'timelineTimeExtentMicros': timeline['timeExtentMicros'],
      'timelineEventCounts': eventCounts,
      'timelineEventDurationsUs': durationSummaries,
    }));

    stdout.writeln(
        'Exported ${events.length} timeline events to $tracePath and metrics to $metricsPath');
  } finally {
    client.close(force: true);
  }
}
