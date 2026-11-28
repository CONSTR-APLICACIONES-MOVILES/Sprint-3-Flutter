import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parchapp/features/andes_events/domain/entities/andes_event.dart';
import 'package:parchapp/features/andes_events/domain/repositories/andes_events_repository.dart';
import 'package:parchapp/features/andes_events/presentation/view_models/andes_events_view_model.dart';

class FakeEvents implements AndesEventsRepository {
  final List<AndesEvent> events;
  FakeEvents(this.events);
  @override Future<AndesEventsResult> load() async => AndesEventsResult(events, 0);
  @override Future<Set<String>> addedIds() async => {};
  @override Future<void> remove(AndesEvent event) async {}
  @override Future<void> add(AndesEvent event) async {}
}
void main() {
  final start = DateTime(2030, 1, 1, 10);
  Map<String, dynamic> data() => {'title': 'Lecture', 'description': 'Robotics discussion', 'category': 'ACADEMIC', 'location': 'Library', 'start': Timestamp.fromDate(start), 'end': Timestamp.fromDate(start.add(const Duration(hours: 1))), 'published': true};
  test('parses and validates published events', () {
    final event = AndesEvent.parse('id', data());
    expect(event?.category, 'academic');
    expect(event?.id, 'id');
    expect(AndesEvent.parse('id', data()..remove('title')), isNull);
    expect(AndesEvent.parse('id', data()..['end'] = 'invalid'), isNull);
    expect(AndesEvent.parse('id', data()..['end'] = Timestamp.fromDate(start)), isNull);
  });
  test('search, filters, ordering and added state', () async {
    final first = AndesEvent.parse('1', data())!;
    final second = AndesEvent.parse('2', data()..['title'] = 'Concert'..['category'] = 'Cultural'..['start'] = Timestamp.fromDate(start.add(const Duration(days: 1)))..['end'] = Timestamp.fromDate(start.add(const Duration(days: 1, hours: 1))))!;
    final vm = AndesEventsViewModel(FakeEvents([second, first]));
    await vm.load();
    expect(vm.filtered.map((e) => e.id), ['1', '2']);
    for (final query in ['lecture', 'ROBOTICS', 'library']) { vm.search(query); expect(vm.filtered.map((e) => e.id), contains('1')); }
    vm.search(''); vm.filter('cultural'); expect(vm.filtered.single.id, '2');
    await vm.add(first); expect(vm.added, contains('1'));
    vm.dispose();
  });
}
