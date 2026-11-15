import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../session.dart';

import 'activity_screen.dart';
import 'create_post_screen.dart';
import 'feed_screen.dart';
import 'map_screen.dart';
import 'messages_screen.dart';

/// Bottom navigation: Feed, Map, Messages, My activity, plus the Post button.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  static const _messagesTab = 2;
  static const _activityTab = 3;

  int _tab = 0;
  int _unread = 0;
  Timer? _unreadTimer;
  final _feedKey = GlobalKey<FeedScreenState>();
  final _messagesKey = GlobalKey<MessagesScreenState>();
  final _activityKey = GlobalKey<ActivityScreenState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshUnread();
    _unreadTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshUnread());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unreadTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshUnread();
      if (_tab == _messagesTab) _messagesKey.currentState?.refresh();
    }
  }

  /// The number on the Messages tab. Errors are ignored: it's only a hint.
  Future<void> _refreshUnread() async {
    try {
      final count = await context.read<Session>().api.unreadCount();
      if (mounted && count != _unread) setState(() => _unread = count);
    } on ApiException {
      // offline or signed out; try again next time
    }
  }

  Future<void> _newPost() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('I found something'),
            subtitle: const Text('Take a photo; we tag where you are'),
            onTap: () => Navigator.pop(context, 'found'),
          ),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('I lost something'),
            subtitle: const Text('Describe it so finders can match it'),
            onTap: () => Navigator.pop(context, 'lost'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CreatePostScreen(postType: choice)),
    );
    if (created == true) {
      _feedKey.currentState?.refresh();
      _activityKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      FeedScreen(key: _feedKey),
      const MapScreen(),
      MessagesScreen(key: _messagesKey, onChanged: _refreshUnread),
      ActivityScreen(key: _activityKey),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newPost,
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('Post'),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) {
          setState(() => _tab = index);
          if (index == _messagesTab) _messagesKey.currentState?.refresh();
          if (index == _activityTab) _activityKey.currentState?.refresh();
          _refreshUnread();
        },
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.dynamic_feed_outlined), selectedIcon: Icon(Icons.dynamic_feed), label: 'Feed'),
          const NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
          NavigationDestination(
            icon: Badge(
                isLabelVisible: _unread > 0, label: Text('$_unread'), child: const Icon(Icons.chat_bubble_outline)),
            selectedIcon:
                Badge(isLabelVisible: _unread > 0, label: Text('$_unread'), child: const Icon(Icons.chat_bubble)),
            label: 'Messages',
          ),
          const NavigationDestination(
              icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'My activity'),
        ],
      ),
    );
  }
}
