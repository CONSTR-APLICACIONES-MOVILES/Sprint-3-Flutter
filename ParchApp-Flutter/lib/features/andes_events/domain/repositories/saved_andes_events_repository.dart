import '../entities/andes_event.dart';

abstract interface class SavedAndesEventsRepository {
  Future<List<AndesEvent>> getSaved(String userId);
  Future<bool> isSaved(String userId, String eventId);
  Future<void> save(String userId, AndesEvent event);
  Future<void> remove(String userId, String eventId);
}
