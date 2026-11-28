import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:parchapp/features/andes_events/domain/entities/andes_event.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_cache.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_repository.dart';
import 'package:parchapp/features/andes_events/presentation/view_models/andes_events_view_model.dart';

final now = DateTime.utc(2030, 1, 1, 12);
AndesEvent makeEvent(String id, int days) => AndesEvent(id: id, title: id, category: 'academic', description: 'test', location: 'campus', start: now.add(Duration(days: days)), end: now.add(Duration(days: days, hours: 1)));
class FakeCache implements AndesEventsCache, AndesCacheIdentity {
  final Object key;
  FakeCache(this.key);
  final reads = <Completer<AndesCacheSnapshot>>[];
  final writes = <List<AndesEvent>>[];
  Completer<void>? writeGate;
  @override Object get coordinationKey => key;
  @override Future<AndesCacheSnapshot> read(AndesCacheWindow w) { final c = Completer<AndesCacheSnapshot>(); reads.add(c); return c.future; }
  @override Future<void> replace(List<AndesEvent> e, AndesCacheWindow w, DateTime t) async { writes.add(e); if (writeGate != null) await writeGate!.future; }
}
class FakeRemote implements AndesEventsRepository {
  final calls = <Completer<AndesEventsResult>>[];
  @override Future<AndesEventsResult> load() { final c = Completer<AndesEventsResult>(); calls.add(c); return c.future; }
  @override Future<Set<String>> addedIds() async => {};
  @override Future<void> remove(AndesEvent event) async {}
  @override Future<void> add(AndesEvent e) async {}
}
Future<void> turn() => Future<void>.delayed(Duration.zero);
void main() {
  test('overlap, cached first, single flight, full catalog and stable filters', () async {
    final cache = FakeCache(Object()), remote = FakeRemote();
    final vm = AndesEventsViewModel(remote, cache: cache, clock: () => now);
    final done = vm.load(); expect(cache.reads, hasLength(1)); expect(remote.calls, hasLength(1));
    final again = vm.refresh(); final resume = vm.onResume(); expect(remote.calls, hasLength(1));
    vm.search('near'); vm.filter('academic');
    cache.reads[0].complete(AndesCacheSnapshot([makeEvent('near', 1)], now));
    cache.reads[1].complete(AndesCacheSnapshot([makeEvent('near', 1)], now));
    await turn(); expect(vm.events.single.id, 'near'); expect(vm.serverConfirmed, false);
    remote.calls[0].complete(AndesEventsResult([makeEvent('near', 1), makeEvent('far', 40)], 0));
    await Future.wait([done, again, resume]); expect(vm.events.map((e) => e.id), ['near', 'far']);
    expect(vm.query, 'near'); expect(vm.category, 'academic'); expect(cache.writes, hasLength(1)); vm.dispose();
  });
  test('server wins over slow cache; failure can retry and disposal is safe', () async {
    final cache = FakeCache(Object()), remote = FakeRemote(); final vm = AndesEventsViewModel(remote, cache: cache, clock: () => now);
    final done = vm.load(); remote.calls.first.complete(AndesEventsResult([makeEvent('server', 40)], 0));
    await turn(); expect(vm.events.single.id, 'server');
    cache.reads.first.complete(AndesCacheSnapshot([makeEvent('stale', 1)], now)); await done;
    expect(vm.events.single.id, 'server');
    final retry = vm.refresh(); remote.calls[1].completeError(StateError('down')); await turn();
    cache.reads.last.complete(AndesCacheSnapshot([makeEvent('cached', 1)], now)); await retry;
    expect(vm.events.single.id, 'cached'); expect(vm.serverConfirmed, false);
    final next = vm.refresh(); vm.dispose(); remote.calls[2].complete(AndesEventsResult([makeEvent('late', 1)], 0)); await next;
    expect(vm.events.single.id, 'cached');
  });
  test('shared cache reconciliations are serialized across screens', () async {
    final key = Object(), a = FakeCache(key), b = FakeCache(key);
    a.writeGate = Completer<void>(); final ra = FakeRemote(), rb = FakeRemote();
    final one = AndesEventsViewModel(ra, cache: a, clock: () => now), two = AndesEventsViewModel(rb, cache: b, clock: () => now);
    final f1 = one.load(); a.reads.single.complete(const AndesCacheSnapshot([], null));
    ra.calls.single.complete(AndesEventsResult([makeEvent('old', 1)], 0)); await turn(); expect(a.writes, hasLength(1));
    final f2 = two.load(); b.reads.single.complete(const AndesCacheSnapshot([], null));
    rb.calls.single.complete(AndesEventsResult([makeEvent('new', 1)], 0)); await turn(); expect(b.writes, isEmpty);
    a.writeGate!.complete(); await Future.wait([f1, f2]); expect(b.writes.single.single.id, 'new');
    one.dispose(); two.dispose();
  });
  test('older delayed server response cannot overwrite newer shared cache', () async {
    final key = Object(), a = FakeCache(key), b = FakeCache(key);
    final ra = FakeRemote(), rb = FakeRemote();
    final one = AndesEventsViewModel(ra, cache: a, clock: () => now);
    final two = AndesEventsViewModel(rb, cache: b, clock: () => now);
    final old = one.load(); a.reads.single.complete(const AndesCacheSnapshot([], null));
    final newer = two.load(); b.reads.single.complete(const AndesCacheSnapshot([], null));
    rb.calls.single.complete(AndesEventsResult([makeEvent('new', 1)], 0)); await newer;
    ra.calls.single.complete(AndesEventsResult([makeEvent('old', 1)], 0)); await old;
    expect(a.writes, isEmpty); expect(b.writes.single.single.id, 'new');
    one.dispose(); two.dispose();
  });

}
