import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../domain/repositories/group_chat.dart';
import '../view_models/group_chat_view_model.dart';

class GroupChatView extends StatefulWidget {
  final GroupChat chat;
  final String groupId;
  final String? friendId;
  final String title;

  const GroupChatView(
      {super.key,
      required this.chat,
      required this.groupId,
      this.friendId,
      required this.title});

  @override
  State<GroupChatView> createState() => _GroupChatViewState();
}

class _GroupChatViewState extends State<GroupChatView> {
  final _input = TextEditingController();
  late final GroupChatViewModel _viewModel = GroupChatViewModel(widget.chat,
      groupId: widget.groupId, friendId: widget.friendId)
    ..start();

  @override
  void dispose() {
    _input.dispose();
    _viewModel.dispose();
    super.dispose();
  }

  void _send() {
    if (_viewModel.send(_input.text)) _input.clear();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
          child: ValueListenableBuilder<GroupChatState>(
              valueListenable: _viewModel,
              builder: (context, state, _) {
                final rows = _rows(state.messages);
                return Column(children: [
                  if (state.fromCache) const _OfflineBanner(),
                  if (state.error != null)
                    Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(state.error!,
                            style: const TextStyle(color: AppColors.error))),
                  Expanded(
                      child: state.loading
                          ? const Center(child: CircularProgressIndicator())
                          : rows.isEmpty
                              ? const Center(
                                  child: Text('No messages yet. Say hi!',
                                      style: _hintStyle))
                              : ListView.builder(
                                  reverse: true,
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 12, 12, 8),
                                  itemCount: rows.length,
                                  itemBuilder: (context, index) {
                                    final row = rows[rows.length - 1 - index];
                                    return row is ChatMessage
                                        ? _Bubble(row)
                                        : _DateDivider(row as String);
                                  })),
                  Container(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                      decoration: _composerDecoration,
                      child: Row(children: [
                        Expanded(
                            child: TextField(
                                controller: _input,
                                minLines: 1,
                                maxLines: 4,
                                maxLength: 2000,
                                textInputAction: TextInputAction.send,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                onSubmitted: (_) => _send(),
                                decoration: _inputDecoration)),
                        const SizedBox(width: 6),
                        IconButton.filled(
                            tooltip: 'Send',
                            onPressed: _send,
                            icon: const Icon(Icons.send)),
                      ])),
                ]);
              })));
}

List<Object> _rows(List<ChatMessage> messages) {
  final rows = <Object>[];
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  DateTime? lastDay;
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    final local = message.sentAt.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (day != lastDay) {
      final gap = today.difference(day).inDays;
      rows.add(gap == 0
          ? 'Today'
          : gap == 1
              ? 'Yesterday'
              : '${day.day}/${day.month}/${day.year}');
      lastDay = day;
    }
    rows.add(message);
  }
  return rows;
}

const _hintStyle = TextStyle(color: AppColors.textSecondary, fontSize: 13);

const _composerDecoration = BoxDecoration(
    color: AppColors.surface,
    border: Border(top: BorderSide(color: AppColors.outlineSoft)));

const _inputDecoration = InputDecoration(
    hintText: 'Write a message',
    counterText: '',
    isDense: true,
    contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(20))));

const _mineBubble = BoxDecoration(
    color: AppColors.primary,
    borderRadius: BorderRadius.all(Radius.circular(16)));

const _otherBubble = BoxDecoration(
    color: AppColors.surface,
    borderRadius: BorderRadius.all(Radius.circular(16)),
    border: Border.fromBorderSide(BorderSide(color: AppColors.outlineSoft)));

const _slotBubble = BoxDecoration(
    color: AppColors.blueTint,
    borderRadius: BorderRadius.all(Radius.circular(16)),
    border: Border.fromBorderSide(BorderSide(color: AppColors.primary)));

const _mineText = TextStyle(color: Colors.white, fontSize: 14.5);
const _otherText = TextStyle(color: AppColors.textPrimary, fontSize: 14.5);
const _mineMeta = TextStyle(color: Color(0xCCFFFFFF), fontSize: 11);
const _otherMeta = TextStyle(color: AppColors.textSecondary, fontSize: 11);
const _senderStyle = TextStyle(
    color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w700);

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  const _Bubble(this.message);

  @override
  Widget build(BuildContext context) {
    final mine = message.mine;
    final time =
        TimeOfDay.fromDateTime(message.sentAt.toLocal()).format(context);
    return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.75),
            child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                decoration: mine
                    ? _mineBubble
                    : message.isSlot
                        ? _slotBubble
                        : _otherBubble,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!mine) Text(message.senderName, style: _senderStyle),
                      if (message.isSlot)
                        Text('Common free slot',
                            style: mine ? _mineMeta : _otherMeta),
                      Text(message.text, style: mine ? _mineText : _otherText),
                      const SizedBox(height: 3),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        if (message.pending) ...[
                          Icon(Icons.schedule,
                              size: 12,
                              color: mine
                                  ? const Color(0xCCFFFFFF)
                                  : AppColors.textSecondary),
                          const SizedBox(width: 3),
                        ],
                        Text(message.pending ? 'Sending...' : time,
                            style: mine ? _mineMeta : _otherMeta),
                      ]),
                    ]))));
  }
}

class _DateDivider extends StatelessWidget {
  final String label;
  const _DateDivider(this.label);

  @override
  Widget build(BuildContext context) => Center(
      child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: const BoxDecoration(
              color: AppColors.outlineSoft,
              borderRadius: BorderRadius.all(Radius.circular(10))),
          child: Text(label, style: _otherMeta)));
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      color: AppColors.blueTint,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: const Row(children: [
        Icon(Icons.cloud_off_outlined, size: 18, color: AppColors.primary),
        SizedBox(width: 8),
        Expanded(
            child: Text(
                'You are offline. Showing saved messages. New messages will be sent when you are back online.',
                style: _hintStyle)),
      ]));
}
