import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../domain/entities/andes_event.dart';
import '../../domain/repositories/andes_events_repository.dart';

class FirebaseAndesEventsRepository implements AndesEventsRepository {
  final FirebaseFirestore firestore;
  final FirebaseAuth auth;
  FirebaseAndesEventsRepository(this.firestore, this.auth);
  String get uid =>
      auth.currentUser?.uid ??
      (throw StateError('Please sign in to use Andes Events.'));
  String slotId(String id) =>
      'andes_${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}';
  CollectionReference<Map<String, dynamic>> get slots =>
      firestore.collection('schedules').doc(uid).collection('slots');
  @override
  Future<AndesEventsResult> load() async {
    final snapshot = await firestore
        .collection('andesEvents')
        .where('published', isEqualTo: true)
        .get(const GetOptions(source: Source.server));
    final events = <AndesEvent>[];
    var invalid = 0;
    for (final doc in snapshot.docs) {
      final event = AndesEvent.parse(doc.id, doc.data());
      if (event == null) {
        invalid++;
      } else if (event.end.isAfter(DateTime.now())) {
        events.add(event);
      }
    }
    events.sort((a, b) => a.start.compareTo(b.start));
    return AndesEventsResult(events, invalid);
  }

  @override
  Future<Set<String>> addedIds() async {
    final result = await slots
        .where('source', isEqualTo: 'andes_events')
        .get(const GetOptions(source: Source.server));
    return result.docs
        .map((d) => d.data()['externalId'])
        .whereType<String>()
        .toSet();
  }

  @override
  Future<void> add(AndesEvent event) async {
    final userId = uid;
    if (event.id.isEmpty ||
        event.title.trim().isEmpty ||
        event.description.trim().isEmpty ||
        event.location.trim().isEmpty ||
        !event.end.isAfter(event.start)) {
      throw StateError('Invalid event data.');
    }
    final id = slotId(event.id);
    final private = firestore
        .collection('schedules')
        .doc(userId)
        .collection('slots')
        .doc(id);
    final shared = firestore
        .collection('availability')
        .doc(userId)
        .collection('slots')
        .doc(id);
    final existing = await private.get(const GetOptions(source: Source.server));
    if (existing.exists) return;
    final day = event.start.toLocal();
    final dayKey =
        '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final times = {
      'start': Timestamp.fromDate(event.start),
      'end': Timestamp.fromDate(event.end),
      'dayKey': dayKey
    };
    final batch = firestore.batch();
    batch.set(private, {
      ...times,
      'title': event.title,
      'description': event.description,
      'location': event.location,
      'source': 'andes_events',
      'externalId': event.id,
      'importedAt': Timestamp.now()
    });
    batch.set(shared, times);
    await batch.commit();
  }
  @override
  Future<void> remove(AndesEvent event) async {
    final userId = uid;
    if (event.id.isEmpty) throw StateError('Invalid event data.');
    final id = slotId(event.id);
    final private = firestore.collection('schedules').doc(userId).collection('slots').doc(id);
    final shared = firestore.collection('availability').doc(userId).collection('slots').doc(id);
    // A transaction requires the server and prevents deleting a different source
    // if a slot ID was reused or changed while this operation was in flight.
    await firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(private);
      if (!snapshot.exists) return;
      final data = snapshot.data();
      if (data?['source'] != 'andes_events' || data?['externalId'] != event.id) {
        throw StateError('This schedule slot belongs to another event.');
      }
      transaction.delete(private);
      transaction.delete(shared);
    });
  }

}
