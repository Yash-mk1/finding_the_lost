import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'chat_screen.dart';

/// The Messages tab: every private chat you're in, newest first.
class MessagesScreen extends StatefulWidget {
  /// Called after a chat is opened and closed, so the tab badge can update.
  final VoidCallback? onChanged;

  const MessagesScreen({super.key, this.onChanged});

  @override
  State<MessagesScreen> createState() => MessagesScreenState();
}

class MessagesScreenState extends State<MessagesScreen> {
  List<Conversation>? _chats;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    final api = context.read<Session>().api;
    try {
      final page = await api.conversations();
      if (!mounted) return;
      setState(() {
        _chats = page.results;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      _loading = false;
    }
  }

  Future<void> _open(Conversation chat) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        conversationId: chat.id,
        title: chat.otherUser.displayName,
        subtitle: chat.postTitle,
        postId: chat.postId,
      ),
    ));
    await refresh();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: _body(),
    );
  }

  Widget _body() {
    final chats = _chats;
    if (_error != null && chats == null) {
      return MessageView(icon: Icons.cloud_off_outlined, title: _error!, actionLabel: 'Try again', onAction: refresh);
    }
    if (chats == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: refresh,
      child: chats.isEmpty
          ? ListView(children: const [
              SizedBox(height: 80),
              MessageView(
                icon: Icons.chat_bubble_outline,
                title: 'No messages yet',
                body: 'Open a post and tap "Message the finder" to ask about an item.',
              ),
            ])
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: chats.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
              itemBuilder: (context, index) => _tile(chats[index]),
            ),
    );
  }

  Widget _tile(Conversation chat) {
    final theme = Theme.of(context);
    final unread = chat.unread > 0;
    final preview = chat.blocked
        ? 'Chat blocked'
        : (chat.lastFromMe ? 'You: ${chat.lastMessage}' : chat.lastMessage);
    return ListTile(
      onTap: () => _open(chat),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 48,
          height: 48,
          child: NetImage(chat.thumbnail, cacheWidth: 150, placeholderIcon: categoryIcon(chat.category)),
        ),
      ),
      title: Row(children: [
        Expanded(
          child: Text(
            chat.otherUser.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: unread ? FontWeight.w700 : FontWeight.w500),
          ),
        ),
        Text(timeAgo(chat.lastMessageAt), style: theme.textTheme.bodySmall),
      ]),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TypeBadge(chat.postType),
          const SizedBox(width: 6),
          Expanded(
            child: Text(chat.postTitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium),
          ),
        ]),
        const SizedBox(height: 2),
        Row(children: [
          Expanded(
            child: Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                color: unread ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (unread)
            Badge(
              label: Text('${chat.unread}'),
              backgroundColor: theme.colorScheme.primary,
              textColor: theme.colorScheme.onPrimary,
            ),
        ]),
      ]),
      isThreeLine: true,
    );
  }
}
