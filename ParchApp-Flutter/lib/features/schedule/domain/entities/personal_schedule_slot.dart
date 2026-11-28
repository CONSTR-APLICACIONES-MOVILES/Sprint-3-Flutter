class PersonalScheduleSlot {
  final String id;
  final String title;
  final String? description;
  final String? location;
  final DateTime start;
  final DateTime end;

  const PersonalScheduleSlot({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.description,
    this.location,
  });

  PersonalScheduleSlot copyWith({
    String? id,
    String? title,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
    bool clearDescription = false,
    bool clearLocation = false,
  }) {
    return PersonalScheduleSlot(
      id: id ?? this.id,
      title: title ?? this.title,
      description: clearDescription
          ? null
          : description ?? this.description,
      location: clearLocation
          ? null
          : location ?? this.location,
      start: start ?? this.start,
      end: end ?? this.end,
    );
  }
}