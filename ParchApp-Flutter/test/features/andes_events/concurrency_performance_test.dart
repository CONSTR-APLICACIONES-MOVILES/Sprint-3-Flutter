import 'package:flutter_test/flutter_test.dart';
import 'package:parchapp/features/andes_events/domain/entities/andes_event.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_cache.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_repository.dart';
import 'package:parchapp/features/andes_events/presentation/view_models/andes_events_view_model.dart';

final now = DateTime.utc(2030, 1, 1);
final cached = AndesEvent(id: 'cached', title: 'cached', description: 'test', category: 'academic', location: 'campus', start: now.add(const Duration(days: 1)), end: now.add(const Duration(days: 1, hours: 1)));
class TimedCache implements AndesEventsCache {
  int readMs = 0;
  @override Future<AndesCacheSnapshot> read(AndesCacheWindow w) async { final watch = Stopwatch()..start(); await Future<void>.delayed(const Duration(milliseconds: 80)); readMs = watch.elapsedMilliseconds; return AndesCacheSnapshot([cached], now); }
  @override Future<void> replace(List<AndesEvent> e, AndesCacheWindow w, DateTime t) async {}
}
class TimedRemote implements AndesEventsRepository {
  int durationMs = 0, calls = 0;
  @override Future<AndesEventsResult> load() async { calls++; final watch = Stopwatch()..start(); await Future<void>.delayed(const Duration(milliseconds: 160)); durationMs = watch.elapsedMilliseconds; return AndesEventsResult([cached], 0); }
  @override Future<Set<String>> addedIds() async => {};
  @override Future<void> remove(AndesEvent event) async {}
  @override Future<void> add(AndesEvent e) async {}
}
void main() {
  test('measure equivalent controlled sequential and concurrent I/O', () async {
    final seqCache = TimedCache(), seqRemote = TimedRemote();
    var watch = Stopwatch()..start(); await seqCache.read(AndesCacheWindow(now)); final seqFirst = watch.elapsedMilliseconds; await seqRemote.load(); final seqTotal = watch.elapsedMilliseconds;
    final cache = TimedCache(), remote = TimedRemote(); final vm = AndesEventsViewModel(remote, cache: cache, clock: () => now);
    watch = Stopwatch()..start(); int? first, server;
    vm.addListener(() { if (vm.events.isNotEmpty) { first ??= watch.elapsedMilliseconds; if (vm.serverConfirmed) server ??= watch.elapsedMilliseconds; } });
    final load = vm.load(); final duplicate1 = vm.refresh(); final duplicate2 = vm.refresh(); await Future.wait([load, duplicate1, duplicate2]);
    // ignore: avoid_print
    print('MEASURE sequential cache=${seqCache.readMs}ms remote=${seqRemote.durationMs}ms first=${seqFirst}ms server=${seqTotal}ms; concurrent cache=${cache.readMs}ms remote=${remote.durationMs}ms first=${first}ms server=${server}ms avoided=${3 - remote.calls}');
    expect(remote.calls, 1); expect(first, isNotNull); expect(server, isNotNull); vm.dispose();
  });
}
