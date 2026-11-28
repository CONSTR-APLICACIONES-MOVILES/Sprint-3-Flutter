import 'package:cloud_firestore/cloud_firestore.dart';

class AndesEvent {
  final String id, title, description, category, location;
  final DateTime start, end;
  final String? sourceUrl;
  const AndesEvent(
      {required this.id,
      required this.title,
      required this.description,
      required this.category,
      required this.location,
      required this.start,
      required this.end,
      this.sourceUrl});

  static AndesEvent? parse(String id, Map<String, dynamic> data) {
    final title = data['title'],
        description = data['description'],
        category = data['category'],
        location = data['location'];
    final start = data['start'], end = data['end'], url = data['sourceUrl'];
    if (id.isEmpty ||
        title is! String ||
        title.trim().isEmpty ||
        description is! String ||
        description.trim().isEmpty ||
        category is! String ||
        category.trim().isEmpty ||
        location is! String ||
        location.trim().isEmpty ||
        start is! Timestamp ||
        end is! Timestamp ||
        data['published'] != true ||
        (url != null && url is! String)) return null;
    final from = start.toDate().toLocal(), to = end.toDate().toLocal();
    if (!to.isAfter(from)) return null;
    final normalized = category.trim().toLowerCase();
    return AndesEvent(
        id: id,
        title: title.trim(),
        description: description.trim(),
        category: const ['academic', 'cultural', 'sports'].contains(normalized)
            ? normalized
            : 'other',
        location: location.trim(),
        start: from,
        end: to,
        sourceUrl: url as String?);
  }
}
