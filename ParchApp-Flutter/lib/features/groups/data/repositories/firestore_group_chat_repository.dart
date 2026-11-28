import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../domain/repositories/group_chat.dart';

class FirestoreGroupChatRepository implements GroupChat {
  static const limit = 100;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  FirestoreGroupChatRepository(this._firestore, this._auth);

  String _uid() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('Sign in to use the chat.');
    return uid;
  }

  CollectionReference<Map<String, dynamic>> _collection(
      String groupId, String? friendId) {
    if (friendId == null) {
      return _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages');
    }
    final uid = _uid();
    final pair = uid.compareTo(friendId) < 0
        ? '${uid}_$friendId'
        : '${friendId}_$uid';
    return _firestore
        .collection('directChats')
        .doc(pair)
        .collection('messages');
  }

  @override
  Stream<ChatSnapshot> messages(String groupId, {String? friendId}) {
    final uid = _uid();
    return _collection(groupId, friendId)
        .orderBy('createdAt')
        .limitToLast(limit)
        .snapshots(includeMetadataChanges: true)
        .map((snapshot) {
      final docs = snapshot.docs;
      final rows = <ChatMessage>[];
      for (var i = 0; i < docs.length; i++) {
        final doc = docs[i];
        final data = doc.data();
        final createdAt = data['createdAt'];
        final senderId = data['senderId'] as String? ?? '';
        rows.add(ChatMessage(
            id: doc.id,
            kind: data['kind'] as String? ?? 'text',
            senderId: senderId,
            senderName: data['senderName'] as String? ?? 'Member',
            senderInitials: data['senderInitials'] as String? ?? '?',
            text: data['text'] as String? ?? '',
            sentAt:
                createdAt is Timestamp ? createdAt.toDate() : DateTime.now(),
            mine: senderId == uid,
            pending: doc.metadata.hasPendingWrites));
      }
      return ChatSnapshot(List<ChatMessage>.unmodifiable(rows),
          fromCache: snapshot.metadata.isFromCache);
    });
  }

  @override
  Future<void> send(String groupId, String text, {String? friendId}) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Sign in to use the chat.');
    final name = _name(user);
    await _collection(groupId, friendId).add({
      'senderId': user.uid,
      'senderName': name,
      'senderInitials': _initials(name),
      'text': text,
      'kind': 'text',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static String _name(User user) {
    final display = user.displayName?.trim() ?? '';
    final email = user.email ?? '';
    final name = display.isNotEmpty
        ? display
        : email.isNotEmpty
            ? email.split('@').first
            : 'Member';
    return name.length > 80 ? name.substring(0, 80) : name;
  }

  static String _initials(String name) {
    final parts = name.split(' ');
    final letters = StringBuffer();
    for (var i = 0; i < parts.length && letters.length < 2; i++) {
      if (parts[i].isNotEmpty) letters.write(parts[i][0].toUpperCase());
    }
    return letters.isEmpty ? '?' : letters.toString();
  }
}
