import 'dart:math' as math;

const mapTileHeaders = {'User-Agent': 'ParchApp/1.0 student project'};

abstract interface class ActivityHistory {
  Future<HistorySnapshot> load();
  Future<void> prefetch();
}

class HistorySnapshot {
  final List<HistoryActivity> activities;
  final DateTime savedAt;
  final bool offline;
  const HistorySnapshot(this.activities, this.savedAt, {this.offline = false});
}

class HistoryActivity {
  final String id;
  final String title;
  final String place;
  final DateTime startsAt;
  final bool confirmed;
  final int people;
  final double? latitude;
  final double? longitude;

  const HistoryActivity(
      {required this.id,
      required this.title,
      required this.place,
      required this.startsAt,
      required this.confirmed,
      required this.people,
      this.latitude,
      this.longitude});

  String? get mapTile {
    final lat = latitude;
    final lng = longitude;
    if (lat == null || lng == null) return null;
    const zoom = 16;
    const scale = 1 << zoom;
    final radians = lat * math.pi / 180;
    final x = ((lng + 180) / 360 * scale).floor();
    final y = ((1 -
                math.log(math.tan(radians) + 1 / math.cos(radians)) /
                    math.pi) /
            2 *
            scale)
        .floor();
    return 'https://tile.openstreetmap.org/$zoom/$x/$y.png';
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'place': place,
        'startsAt': startsAt.toIso8601String(),
        'confirmed': confirmed,
        'people': people,
        'latitude': latitude,
        'longitude': longitude,
      };

  static HistoryActivity? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final startsAt = DateTime.tryParse('${raw['startsAt']}');
    final id = raw['id'];
    final title = raw['title'];
    if (startsAt == null || id is! String || title is! String) return null;
    return HistoryActivity(
        id: id,
        title: title,
        place: raw['place'] as String? ?? '',
        startsAt: startsAt,
        confirmed: raw['confirmed'] == true,
        people: (raw['people'] as num?)?.toInt() ?? 0,
        latitude: (raw['latitude'] as num?)?.toDouble(),
        longitude: (raw['longitude'] as num?)?.toDouble());
  }

  static HistoryActivity? fromActivity(Map<String, dynamic> data) {
    if (data['cancelled'] == true) return null;
    final startsAt = DateTime.tryParse('${data['startTime']}');
    final id = data['id'];
    final title = data['title'];
    if (startsAt == null || id is! String || title is! String) return null;
    final details = data['locationDetails'];
    final participants = data['participants'];
    return HistoryActivity(
        id: id,
        title: title,
        place: data['location'] as String? ?? '',
        startsAt: startsAt,
        confirmed: data['status'] == 'CONFIRMED',
        people: participants is List ? participants.length : 0,
        latitude:
            details is Map ? (details['latitude'] as num?)?.toDouble() : null,
        longitude:
            details is Map ? (details['longitude'] as num?)?.toDouble() : null);
  }
}