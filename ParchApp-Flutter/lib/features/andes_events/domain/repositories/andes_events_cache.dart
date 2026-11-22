import '../entities/andes_event.dart';

class AndesCacheSnapshot {
  final List<AndesEvent> events;
  final DateTime? lastSync;
  const AndesCacheSnapshot(this.events, this.lastSync);
}

/// Bogotá currently observes UTC-05:00 year round.
class AndesCacheWindow {
  final DateTime now;
  final DateTime start;
  final DateTime end;
  AndesCacheWindow(DateTime instant)
      : now = instant.toUtc(),
        start = _midnight(instant),
        end = _midnight(instant).add(const Duration(days: 15));
  static DateTime _midnight(DateTime instant) {
    final bogota = instant.toUtc().subtract(const Duration(hours: 5));
    return DateTime.utc(bogota.year, bogota.month, bogota.day, 5);
  }
  bool includes(AndesEvent event) => event.end.isAfter(now) &&
      event.end.isAfter(start) && event.start.isBefore(end);
}

abstract interface class AndesEventsCache {
  Future<AndesCacheSnapshot> read(AndesCacheWindow window);
  Future<void> replace(List<AndesEvent> events, AndesCacheWindow window, DateTime syncedAt);
}

/// Optional identity for coordinating writes by separate repository instances.
abstract interface class AndesCacheIdentity {
  Object get coordinationKey;
}
