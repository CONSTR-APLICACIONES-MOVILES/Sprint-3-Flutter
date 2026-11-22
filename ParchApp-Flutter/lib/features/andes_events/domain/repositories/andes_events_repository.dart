import '../entities/andes_event.dart';

class AndesEventsResult {
  final List<AndesEvent> events;
  final int invalidCount;
  const AndesEventsResult(this.events, this.invalidCount);
}

abstract interface class AndesEventsRepository {
  Future<AndesEventsResult> load();
  Future<Set<String>> addedIds();
  Future<void> add(AndesEvent event);
  Future<void> remove(AndesEvent event);
}
