import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'claims_review_screen.dart';
import 'map_screen.dart';

class PostDetailScreen extends StatefulWidget {
  final int postId;
  const PostDetailScreen({super.key, required this.postId});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  Post? _post;
  List<Comment> _comments = [];
  String? _error;
  bool _sending = false;
  int? _replyTo;
  final _commentField = TextEditingController();
  final _commentFocus = FocusNode();

  ApiClient get _api => context.read<Session>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentField.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([_api.post(widget.postId), _api.comments(widget.postId)]);
      if (!mounted) return;
      setState(() {
        _post = results[0] as Post;
        _comments = results[1] as List<Comment>;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.statusCode == 404 ? 'This post was removed or is under review.' : e.message);
    }
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (done != null && mounted) showSnack(context, done);
      await _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  Future<void> _vote() async {
    final post = _post!;
    try {
      await _api.toggleVote(post.id);
      await _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  Future<void> _sendComment() async {
    final text = _commentField.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await _api.addComment(widget.postId, text, parent: _replyTo);
      _commentField.clear();
      _replyTo = null;
      _commentFocus.unfocus();
      await _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _claim() async {
    final post = _post!;
    final answer = TextEditingController();
    final message = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Claim this item'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text("The finder asks a question only the owner would know. They'll see your answer and decide."),
            const SizedBox(height: 12),
            Text(post.verificationQuestion, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(controller: answer, autofocus: true, decoration: const InputDecoration(labelText: 'Your answer')),
            const SizedBox(height: 12),
            TextField(
              controller: message,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Message to the finder (optional)'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send claim')),
        ],
      ),
    );
    if (send == true && answer.text.trim().isNotEmpty) {
      await _run(() => _api.sendClaim(post.id, answer.text.trim(), message.text.trim()).then((_) {}),
          done: 'Claim sent. You\'ll see the finder\'s reply here and in My activity.');
    }
  }

  Future<void> _report() async {
    final reasons = context.read<Session>().meta?.reportReasons ?? const [];
    final reason = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Why are you reporting this post?')),
          ...reasons.map((r) => ListTile(title: Text(r.label), onTap: () => Navigator.pop(context, r.value))),
        ]),
      ),
    );
    if (reason == null) return;
    await _run(() async {
      final message = await _api.report(widget.postId, reason, '');
      if (mounted) showSnack(context, message);
    });
  }

  Future<void> _confirm(String title, String body, String action, Future<void> Function() run) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    );
    if (ok == true) await run();
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    if (_error != null && post == null) {
      return Scaffold(
        appBar: AppBar(),
        body: MessageView(icon: Icons.error_outline, title: _error!, actionLabel: 'Try again', onAction: _load),
      );
    }
    if (post == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(post.isFound ? 'Found item' : 'Lost item'),
        actions: [_menu(post)],
      ),
      body: Column(children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
              _photos(post),
              _header(post),
              if (post.isFound && post.handover.isNotEmpty) _guidance(post),
              _claimSection(post),
              _location(post),
              if (post.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(post.description, style: Theme.of(context).textTheme.bodyLarge),
                ),
              _actions(post),
              const Divider(height: 24),
              _commentsList(),
            ]),
          ),
        ),
        _commentBar(),
      ]),
    );
  }

  Widget _menu(Post post) {
    return PopupMenuButton<String>(
      onSelected: (value) {
        switch (value) {
          case 'resolve':
            _confirm(
              post.isFound ? 'Mark as returned?' : 'Mark as found?',
              'The post leaves the feed and shows as resolved.',
              'Yes, it\'s back',
              () => _run(() => _api.resolve(post.id), done: 'Great news! Marked as resolved.'),
            );
          case 'renew':
            _run(() => _api.renew(post.id), done: 'Post will stay up for another month.');
          case 'delete':
            _confirm('Delete this post?', 'This can\'t be undone.', 'Delete', () async {
              try {
                await _api.deletePost(post.id);
                if (mounted) Navigator.pop(context, true);
              } on ApiException catch (e) {
                if (mounted) showSnack(context, e.message, error: true);
              }
            });
          case 'report':
            _report();
        }
      },
      itemBuilder: (context) => post.isOwner
          ? [
              if (post.status != 'returned')
                PopupMenuItem(
                    value: 'resolve', child: Text(post.isFound ? 'Mark as returned' : 'I got it back')),
              const PopupMenuItem(value: 'renew', child: Text('Keep it up another month')),
              const PopupMenuItem(value: 'delete', child: Text('Delete post')),
            ]
          : [const PopupMenuItem(value: 'report', child: Text('Report post'))],
    );
  }

  Widget _photos(Post post) {
    if (post.images.isEmpty) {
      return Container(
        height: 140,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(categoryIcon(post.category), size: 56, color: Theme.of(context).colorScheme.outline),
      );
    }
    return SizedBox(
      height: 300,
      child: PageView.builder(
        itemCount: post.images.length,
        itemBuilder: (context, index) => GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
              body: InteractiveViewer(child: Center(child: NetImage(post.images[index].url, fit: BoxFit.contain))),
            ),
          )),
          child: Stack(fit: StackFit.expand, children: [
            NetImage(post.images[index].url),
            if (post.images.length > 1)
              Positioned(
                right: 12,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                  child: Text('${index + 1}/${post.images.length}', style: const TextStyle(color: Colors.white)),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _header(Post post) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TypeBadge(post.postType),
          const SizedBox(width: 6),
          StatusBadge(post.status),
          const SizedBox(width: 6),
          Icon(categoryIcon(post.category), size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 4),
          Flexible(child: Text(post.categoryLabel, style: theme.textTheme.bodySmall)),
        ]),
        const SizedBox(height: 8),
        Text(post.title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
          Text('by ${post.author.displayName}', style: theme.textTheme.bodySmall),
          if (post.authorReturnedCount > 0)
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.volunteer_activism, size: 14),
              label: Text('Returned ${post.authorReturnedCount} item${post.authorReturnedCount == 1 ? '' : 's'}'),
            ),
          Text('· ${post.isFound ? 'found' : 'lost'} ${timeAgo(post.occurredAt)}', style: theme.textTheme.bodySmall),
        ]),
      ]),
    );
  }

  Widget _guidance(Post post) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(handoverIcon(post.handover), color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(post.handoverLabel,
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
            ),
          ]),
          if (post.handoverDetails.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(post.handoverDetails,
                style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700, color: theme.colorScheme.onSecondaryContainer)),
          ],
          const SizedBox(height: 8),
          Text('What to do', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
          const SizedBox(height: 2),
          Text(post.guidance, style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
        ]),
      ),
    );
  }

  Widget _claimSection(Post post) {
    final theme = Theme.of(context);
    if (!post.claimsEnabled) {
      if (!post.isFound && !post.isOwner && post.isOpen) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            'Seen this item? Leave a comment, or post it as a found item with a photo so the owner can claim it.',
            style: theme.textTheme.bodyMedium,
          ),
        );
      }
      return const SizedBox.shrink();
    }

    if (post.isOwner) {
      final pending = post.pendingClaimCount ?? 0;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: FilledButton.icon(
          icon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.how_to_reg)),
          label: Text(pending > 0 ? 'Review claims ($pending waiting)' : 'Review claims'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ClaimsReviewScreen(post: post)));
            _load();
          },
        ),
      );
    }

    final claim = post.myClaim;
    if (claim != null) {
      final (icon, color, title) = switch (claim.status) {
        'approved' => (Icons.check_circle, Colors.green, 'The finder approved your claim'),
        'rejected' => (Icons.cancel, Colors.red, 'The finder didn\'t approve your claim'),
        _ => (Icons.hourglass_top, Colors.orange, 'Claim sent, waiting for the finder'),
      };
      return Card(
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            ]),
            if (claim.finderResponse.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Message from the finder:', style: theme.textTheme.labelMedium),
              Text(claim.finderResponse, style: theme.textTheme.bodyLarge),
            ],
            if (claim.isApproved) ...[
              const SizedBox(height: 8),
              Text('Meet in a public place. Never pay anyone to get your item back.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            ],
            if (claim.isPending)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _run(() => _api.withdrawClaim(claim.id), done: 'Claim withdrawn.'),
                  child: const Text('Withdraw claim'),
                ),
              ),
          ]),
        ),
      );
    }

    if (!post.isOpen) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: FilledButton.icon(
        icon: const Icon(Icons.front_hand_outlined),
        label: const Text('This is mine: claim it'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
        onPressed: _claim,
      ),
    );
  }

  Widget _location(Post post) {
    final theme = Theme.of(context);
    final point = LatLng(post.latitude, post.longitude);
    final circle = approxCircle(post);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(post.isFound ? 'Where it was found' : 'Where it was lost', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 180,
            child: FlutterMap(
              options: MapOptions(
                initialCenter: point,
                initialZoom: circle != null ? 15 : 16,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag),
              ),
              children: [
                ...baseMapLayers(),
                if (circle != null) CircleLayer(circles: [circle]) else MarkerLayer(markers: [postMarker(post)]),
                osmAttribution(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (post.landmark.isNotEmpty)
          Row(children: [
            const Icon(Icons.place_outlined, size: 18),
            const SizedBox(width: 4),
            Expanded(child: Text(post.landmark, style: theme.textTheme.bodyMedium)),
          ]),
        if (post.locationIsApproximate)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Approximate area (about ${post.approxRadiusM?.round() ?? 250} m). The exact spot is shared once the finder approves your claim.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (post.isOwner && post.accuracyM != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('GPS accuracy when posted: about ${post.accuracyM!.round()} m',
                style: theme.textTheme.bodySmall),
          ),
      ]),
    );
  }

  Widget _actions(Post post) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(children: [
        TextButton.icon(
          onPressed: _vote,
          icon: Icon(post.hasVoted ? Icons.arrow_circle_up : Icons.arrow_circle_up_outlined),
          label: Text('${post.score}  Upvote'),
          style: TextButton.styleFrom(foregroundColor: post.hasVoted ? theme.colorScheme.primary : null),
        ),
        const Spacer(),
        Text('Posted ${timeAgo(post.createdAt)}', style: theme.textTheme.bodySmall),
        const SizedBox(width: 8),
      ]),
    );
  }

  Widget _commentsList() {
    final theme = Theme.of(context);
    final byParent = <int?, List<Comment>>{};
    for (final comment in _comments) {
      byParent.putIfAbsent(comment.parent, () => []).add(comment);
    }

    List<Widget> thread(int? parent, int depth) => [
          for (final comment in byParent[parent] ?? const <Comment>[]) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(16.0 + depth * 18, 6, 16, 0),
              child: Container(
                decoration: depth > 0
                    ? BoxDecoration(border: Border(left: BorderSide(color: theme.dividerColor, width: 2)))
                    : null,
                padding: EdgeInsets.only(left: depth > 0 ? 10 : 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(comment.author.displayName, style: theme.textTheme.labelLarge),
                    if (comment.isPostAuthor) ...[
                      const SizedBox(width: 6),
                      Text(_post!.isFound ? 'FINDER' : 'OWNER',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
                    ],
                    const SizedBox(width: 6),
                    Text(timeAgo(comment.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                  ]),
                  const SizedBox(height: 2),
                  Text(comment.body),
                  if (depth < 4)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () {
                        setState(() => _replyTo = comment.id);
                        _commentFocus.requestFocus();
                      },
                      child: const Text('Reply'),
                    ),
                ]),
              ),
            ),
            ...thread(comment.id, depth + 1),
          ],
        ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text('Comments (${_comments.length})', style: theme.textTheme.titleSmall),
      ),
      if (_comments.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No comments yet. Know whose this is? Say so here.', style: theme.textTheme.bodySmall),
        ),
      ...thread(null, 0),
    ]);
  }

  Widget _commentBar() {
    final replyingTo = _replyTo == null
        ? null
        : _comments.where((c) => c.id == _replyTo).map((c) => c.author.displayName).firstOrNull;
    return SafeArea(
      top: false,
      child: Material(
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (replyingTo != null)
              Row(children: [
                Expanded(child: Text('Replying to $replyingTo', style: Theme.of(context).textTheme.bodySmall)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _replyTo = null),
                ),
              ]),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _commentField,
                  focusNode: _commentFocus,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Add a comment', isDense: true),
                ),
              ),
              IconButton(
                onPressed: _sending ? null : _sendComment,
                icon: _sending
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
