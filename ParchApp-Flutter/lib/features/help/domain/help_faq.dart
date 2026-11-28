class HelpFaq {
  final String id, screen, question, answer;
  final int position;
  const HelpFaq({required this.id, required this.screen, required this.question, required this.answer, required this.position});
  factory HelpFaq.fromMap(Map<String, dynamic> json, {String? documentId}) => HelpFaq(
    id: documentId ?? json['id'] as String, screen: json['screen'] as String,
    question: json['question'] as String, answer: json['answer'] as String,
    position: (json['position'] as num?)?.toInt() ?? 0);
  Map<String, Object> toMap() => {'id': id, 'screen': screen, 'question': question, 'answer': answer, 'position': position};
}

const helpTitles = {'groups': 'Groups', 'schedule': 'Schedule', 'compare': 'Compare availability', 'chat': 'Chat', 'andes': 'Andes Events', 'dashboard': 'Home', 'status': 'Status', 'alerts': 'Alerts', 'profile': 'Profile', 'general': 'General'};
List<String> helpSectionOrder(List<HelpFaq> faqs, String origin) {
  final screens = faqs.map((f) => f.screen).toSet().toList()..sort();
  screens.remove('general');
  if (origin != 'general' && screens.remove(origin)) screens.insert(0, origin);
  if (faqs.any((f) => f.screen == 'general')) screens.add('general');
  return screens;
}
String normalizeHelpQuery(String text) => text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
String helpMatchQuery(String text) => RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(normalizeHelpQuery(text)).map((m) => '${m.group(0)}*').join(' ');
