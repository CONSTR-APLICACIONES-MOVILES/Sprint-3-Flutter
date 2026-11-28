class ChatMessage {
  final String id;
  final String kind;
  final String senderId;
  final String senderName;
  final String senderInitials;
  final String text;
  final DateTime sentAt;
  final bool mine;
  final bool pending;

  const ChatMessage(
      {required this.id,
      required this.kind,
      required this.senderId,
      required this.senderName,
      required this.senderInitials,
      required this.text,
      required this.sentAt,
      required this.mine,
      required this.pending});

  bool get isSlot => kind == 'slot';
}

class ChatSnapshot {
  final List<ChatMessage> messages;
  final bool fromCache;
  const ChatSnapshot(this.messages, {this.fromCache = false});
}

abstract interface class GroupChat {
  Stream<ChatSnapshot> messages(String groupId, {String? friendId});
  Future<void> send(String groupId, String text, {String? friendId});
}
