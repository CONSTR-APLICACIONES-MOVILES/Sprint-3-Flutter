import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:parchapp/features/andes_events/domain/entities/andes_event.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_repository.dart';
import 'package:parchapp/features/andes_events/presentation/view_models/andes_events_view_model.dart';

class ScheduleEvents implements AndesEventsRepository {
  Completer<void>? removal;
  int removeCalls = 0;
  @override Future<AndesEventsResult> load() async => const AndesEventsResult([], 0);
  @override Future<Set<String>> addedIds() async => {'event'};
  @override Future<void> add(AndesEvent event) async {}
  @override Future<void> remove(AndesEvent event) { removeCalls++; return removal!.future; }
}
void main() {
  final start = DateTime(2030, 1, 1, 10);
  final event = AndesEvent(id: 'event', title: 'Event', category: 'academic', description: 'Description', location: 'Campus', start: start, end: start.add(const Duration(hours: 1)));
  test('remove remains selected until confirmed and refreshes schedule on return', () async {
    final repository = ScheduleEvents()..removal = Completer<void>();
    final vm = AndesEventsViewModel(repository);
    await vm.load(); expect(vm.added, contains('event'));
    final request = vm.remove(event);
    expect(vm.added, contains('event')); expect(vm.adding, contains('event'));
    await vm.remove(event); expect(repository.removeCalls, 1);
    repository.removal!.complete(); expect(await request, isNull);
    expect(vm.added, isNot(contains('event'))); expect(vm.changed, isTrue);
    vm.dispose();
  });
  test('failed or offline removal keeps the event selected', () async {
    final repository = ScheduleEvents()..removal = Completer<void>();
    final vm = AndesEventsViewModel(repository);
    await vm.load(); final request = vm.remove(event);
    repository.removal!.completeError(StateError('Rejected'));
    expect(await request, 'Rejected'); expect(vm.added, contains('event')); expect(vm.changed, isFalse);
    vm.networkAvailable = false;
    expect(await vm.remove(event), contains('internet connection'));
    expect(repository.removeCalls, 1); expect(vm.added, contains('event'));
    vm.dispose();
  });
}
