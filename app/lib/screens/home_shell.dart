import 'package:material_ui/material_ui.dart';

import 'activity_screen.dart';
import 'create_post_screen.dart';
import 'feed_screen.dart';
import 'map_screen.dart';

/// Bottom navigation: Feed, Map, Post (+), My activity.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  final _feedKey = GlobalKey<FeedScreenState>();
  final _activityKey = GlobalKey<ActivityScreenState>();

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
          if (index == 2) _activityKey.currentState?.refresh();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dynamic_feed_outlined), selectedIcon: Icon(Icons.dynamic_feed), label: 'Feed'),
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'My activity'),
        ],
      ),
    );
  }
}
