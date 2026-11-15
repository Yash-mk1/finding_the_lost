import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'post_detail_screen.dart';

/// A private chat about one post. New messages are fetched every few seconds
/// while the screen is open.
class ChatScreen extends StatefulWidget {
  final int conversationId;
  final String title; // the other person's name
  final String subtitle; // the post's title
  final int? postId;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.title,
    this.subtitle = '',
    this.postId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  static const _pollEvery = Duration(seconds: 4);

  final _messages = <ChatMessage>[];
  final _controller = TextEditingController();
  Timer? _timer;
  bool _loading = true;
  bool _sending = false;
  bool _polling = false;
  bool _blocked = false;
  bool _blockedByMe = false;
  String _safetyNote = '';
  String? _error;

  ApiClient get _api => context.read<Session>().api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll();
    _timer = Timer.periodic(_pollEvery, (_) => _poll());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Stop asking the server while the app is in the background.
    if (state == AppLifecycleState.resumed) {
      _timer?.cancel();
      _poll();
      _timer = Timer.periodic(_pollEvery, (_) => _poll());
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final update = await _api.messages(widget.conversationId, afterId: _messages.isEmpty ? null : _messages.last.id);
      if (!mounted) return;
      setState(() {
        final known = _messages.map((m) => m.id).toSet();
        _messages.addAll(update.messages.where((m) => !known.contains(m.id)));
        _blocked = update.blocked;
        _blockedByMe = update.blockedByMe;
        if (update.safetyNote.isNotEmpty) _safetyNote = update.safetyNote;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_messages.isEmpty) _error = e.message;
      });
    } finally {
      _polling = false;
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final message = await _api.sendMessage(widget.conversationId, text);
      if (!mounted) return;
      _controller.clear();
      setState(() {
        if (!_messages.any((m) => m.id == message.id)) _messages.add(message);
      });
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _menuAction(String value) async {
    try {
      switch (value) {
        case 'post':
          final id = widget.postId;
          if (id != null) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: id)));
        case 'block':
          final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Block this chat?'),
              content: const Text('Neither of you will be able to send messages. You can unblock it later.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Block')),
              ],
            ),
          );
          if (ok == true) {
            final message = await _api.blockChat(widget.conversationId);
            if (mounted) showSnack(context, message);
            _poll();
          }
        case 'unblock':
          final message = await _api.unblockChat(widget.conversationId);
          if (mounted) showSnack(context, message);
          _poll();
        case 'report':
          final reason = await promptText(
            context,
            title: 'Report this chat?',
            message: 'A moderator will read it. Tell us what happened (optional).',
            hint: 'e.g. Asked me to pay to get the item back',
            confirm: 'Report',
            required: false,
          );
          if (reason != null) {
            final message = await _api.reportChat(widget.conversationId, reason);
            if (mounted) showSnack(context, message);
          }
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (widget.subtitle.isNotEmpty)
            Text(widget.subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
        ]),
        actions: [
          PopupMenuButton<String>(
            onSelected: _menuAction,
            itemBuilder: (context) => [
              if (widget.postId != null) const PopupMenuItem(value: 'post', child: Text('View post')),
              if (!_blocked) const PopupMenuItem(value: 'block', child: Text('Block chat')),
              if (_blockedByMe) const PopupMenuItem(value: 'unblock', child: Text('Unblock chat')),
              const PopupMenuItem(value: 'report', child: Text('Report chat')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        if (_safetyNote.isNotEmpty)
          Container(
            width: double.infinity,
            color: theme.colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Icon(Icons.shield_outlined, size: 18, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_safetyNote,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
              ),
            ]),
          ),
        Expanded(child: _body(theme)),
        _composer(theme),
      ]),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return MessageView(icon: Icons.cloud_off_outlined, title: _error!, actionLabel: 'Try again', onAction: _poll);
    }
    if (_messages.isEmpty) {
      return const MessageView(
        icon: Icons.chat_bubble_outline,
        title: 'No messages yet',
        body: 'Say hello. Ask about details only the owner would know, and agree to meet somewhere public.',
      );
    }
    // Reversed so the newest message sits at the bottom, by the text box.
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[_messages.length - 1 - index];
        return _bubble(theme, message);
      },
    );
  }

  Widget _bubble(ThemeData theme, ChatMessage message) {
    final mine = message.fromMe;
    final background = mine ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHigh;
    final foreground = mine ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 4),
              bottomRight: Radius.circular(mine ? 4 : 18),
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            SelectableText(message.body, style: theme.textTheme.bodyLarge?.copyWith(color: foreground)),
            const SizedBox(height: 2),
            Text(timeAgo(message.createdAt),
                style: theme.textTheme.labelSmall?.copyWith(color: foreground.withValues(alpha: 0.7))),
          ]),
        ),
      ),
    );
  }

  Widget _composer(ThemeData theme) {
    if (_blocked) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _blockedByMe ? 'You blocked this chat. Unblock it from the menu to send messages.' : 'This chat is blocked.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      );
    }
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                maxLength: 2000,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Message',
                  counterText: '',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            IconButton(
              tooltip: 'Send',
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Opens (or reuses) the chat about [post] and shows it. The author passes
/// [withUser] to message someone who claimed or commented.
Future<void> openChatAbout(BuildContext context, Post post, {Author? withUser}) async {
  final api = context.read<Session>().api;
  try {
    final convo = await api.openConversation(post.id, withUser: withUser?.id);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        conversationId: convo.id,
        title: convo.otherUser.displayName,
        subtitle: post.title,
        postId: post.id,
      ),
    ));
  } on ApiException catch (e) {
    if (context.mounted) showSnack(context, e.message, error: true);
  }
}
