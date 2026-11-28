import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/repositories/group_chat.dart';

class GroupChatState {
  final bool loading;
  final List<ChatMessage> messages;
  final bool fromCache;
  final String? error;

  const GroupChatState(
      {this.loading = false,
      this.messages = const [],
      this.fromCache = false,
      this.error});
}

class GroupChatViewModel extends ValueNotifier<GroupChatState> {
  final GroupChat _chat;
  final String groupId;
  final String? friendId;
  StreamSubscription<ChatSnapshot>? _subscription;
  bool _disposed = false;

  GroupChatViewModel(this._chat, {required this.groupId, this.friendId})
      : super(const GroupChatState(loading: true));

  void start() {
    _subscription?.cancel();
    try {
      _subscription = _chat.messages(groupId, friendId: friendId).listen(
          (snapshot) {
        if (_disposed) return;
        value = GroupChatState(
            messages: snapshot.messages, fromCache: snapshot.fromCache);
      }, onError: (Object _) {
        if (_disposed) return;
        value = GroupChatState(
            messages: value.messages,
            fromCache: value.fromCache,
            error: 'We could not load this chat. Try again later.');
      });
    } catch (_) {
      value = const GroupChatState(error: 'Sign in to use the chat.');
    }
  }

  bool send(String text) {
    final clean = text.trim();
    if (clean.isEmpty || clean.length > 2000) return false;
    _chat.send(groupId, clean, friendId: friendId).catchError((Object _) {
      if (_disposed) return;
      value = GroupChatState(
          messages: value.messages,
          fromCache: value.fromCache,
          error: 'A message could not be sent.');
    });
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
