import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'post_detail_screen.dart';

/// "My activity": your own posts (with claims waiting) and claims you sent.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => ActivityScreenState();
}

class ActivityScreenState extends State<ActivityScreen> {
  List<Post>? _posts;
  List<Claim>? _claims;
  String? _error;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final api = context.read<Session>().api;
    try {
      final results = await Future.wait([api.myPosts(), api.myClaims()]);
      if (!mounted) return;
      setState(() {
        _posts = (results[0] as PagedResult<Post>).results;
        _claims = (results[1] as PagedResult<Claim>).results;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _openPost(int id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: id)));
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final user = session.user;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(user == null ? 'My activity' : 'Hi, ${user.displayName}'),
          actions: [
            IconButton(
              tooltip: 'Log out',
              icon: const Icon(Icons.logout),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Log out?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log out')),
                    ],
                  ),
                );
                if (ok == true) await session.logout();
              },
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'My posts'), Tab(text: 'My claims')]),
        ),
        body: _error != null
            ? MessageView(icon: Icons.cloud_off_outlined, title: _error!, actionLabel: 'Try again', onAction: refresh)
            : TabBarView(children: [_postsTab(), _claimsTab()]),
      ),
    );
  }

  Widget _postsTab() {
    final posts = _posts;
    if (posts == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: refresh,
      child: posts.isEmpty
          ? ListView(children: const [
              SizedBox(height: 80),
              MessageView(
                icon: Icons.post_add,
                title: "You haven't posted yet",
                body: 'Tap Post to share something you found or lost.',
              ),
            ])
          : ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              itemCount: posts.length,
              itemBuilder: (context, index) {
                final post = posts[index];
                return PostCard(
                  post: post,
                  onTap: () => _openPost(post.id),
                  trailing: post.pendingClaims > 0
                      ? Badge(
                          label: Text('${post.pendingClaims} claim${post.pendingClaims == 1 ? '' : 's'}'),
                          backgroundColor: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                );
              },
            ),
    );
  }

  Widget _claimsTab() {
    final claims = _claims;
    if (claims == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: refresh,
      child: claims.isEmpty
          ? ListView(children: const [
              SizedBox(height: 80),
              MessageView(
                icon: Icons.front_hand_outlined,
                title: 'No claims sent',
                body: 'When you claim an item a finder kept, you can follow it here.',
              ),
            ])
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemCount: claims.length,
              itemBuilder: (context, index) {
                final claim = claims[index];
                final (icon, color, label) = switch (claim.status) {
                  'approved' => (Icons.check_circle, Colors.green, 'Approved'),
                  'rejected' => (Icons.cancel, Colors.red, 'Not approved'),
                  _ => (Icons.hourglass_top, Colors.orange, 'Waiting for the finder'),
                };
                return Card(
                  child: ListTile(
                    leading: Icon(icon, color: color),
                    title: Text(claim.postTitle),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('$label · ${timeAgo(claim.createdAt)}'),
                      if (claim.finderResponse.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('Finder: ${claim.finderResponse}',
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                        ),
                    ]),
                    isThreeLine: claim.finderResponse.isNotEmpty,
                    onTap: () => _openPost(claim.postId),
                  ),
                );
              },
            ),
    );
  }
}
