import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../domain/entities/andes_event.dart';
import '../../domain/services/schedule_outbox.dart';

/// Transactions are server-only: no second SDK-managed offline write queue.
class FirebaseScheduleIntentSender implements ScheduleIntentSender {
  final FirebaseFirestore firestore;
  final FirebaseAuth auth;
  final String project;
  final DateTime Function() clock;
  FirebaseScheduleIntentSender(this.firestore, this.auth, {DateTime Function()? clock}) : project = firestore.app.options.projectId, clock = clock ?? DateTime.now;
  void _verify(String userId) {
    if (auth.currentUser == null || '$project:${auth.currentUser!.uid}' != userId) throw StateError('Please sign in to the original account.');
  }
  @override
  Future<void> send(String userId, AndesEvent event) async {
    _verify(userId);
    final uid = auth.currentUser!.uid;
    final id = 'andes_${base64Url.encode(utf8.encode(event.id)).replaceAll('=', '')}';
    final private = firestore.collection('schedules').doc(uid).collection('slots').doc(id);
    final shared = firestore.collection('availability').doc(uid).collection('slots').doc(id);
    final catalog = firestore.collection('andesEvents').doc(event.id);
    await firestore.runTransaction((tx) async {
      _verify(userId);
      final currentSlot = await tx.get(private);
      final currentShared = await tx.get(shared);
      if (currentSlot.exists) {
        final data = currentSlot.data()!;
        if (data['source'] != 'andes_events' || data['externalId'] != event.id || data['start'] is! Timestamp || data['end'] is! Timestamp || data['dayKey'] is! String) throw StateError('The existing schedule slot conflicts with this event.');
        final busy = {'start': data['start'], 'end': data['end'], 'dayKey': data['dayKey']};
        if (!currentShared.exists || currentShared.data()!['start'] != busy['start'] || currentShared.data()!['end'] != busy['end'] || currentShared.data()!['dayKey'] != busy['dayKey']) tx.set(shared, busy);
        return;
      }
      final record = await tx.get(catalog);
      if (!record.exists) throw StateError('This event is no longer available.');
      final latest = AndesEvent.parse(event.id, record.data()!);
      if (latest == null || !latest.end.isAfter(clock())) throw StateError('This event is invalid or has already ended.');
      if (latest.start != event.start || latest.end != event.end || latest.location != event.location) throw StateError('Event time or location changed. Review the updated event before adding it.');
      _verify(userId);
      final day = latest.start.toLocal();
      final dayKey = '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      final times = {'start': Timestamp.fromDate(latest.start), 'end': Timestamp.fromDate(latest.end), 'dayKey': dayKey};
      tx.set(private, {...times, 'title': latest.title, 'description': latest.description, 'location': latest.location, 'source': 'andes_events', 'externalId': latest.id, 'importedAt': Timestamp.now()});
      tx.set(shared, times);
    });
  }
}
