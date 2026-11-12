import 'package:finding_the_lost/models.dart';
import 'package:finding_the_lost/widgets.dart';
import 'package:flutter_test/flutter_test.dart';


const kFoundColor = Color(0xFF2E7D5B);
const kLostColor = Color(0xFFD9822B);

Color typeColor(String postType) => postType == 'found' ? kFoundColor : kLostColor;

String timeAgo(DateTime? time) {
  if (time == null) return '';
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays < 7) return '${diff.inDays} d ago';
  return '${time.day}/${time.month}/${time.year}';
}

String formatDistance(int? metres) {
  if (metres == null) return '';
  if (metres < 1000) return '$metres m away';
  return '${(metres / 1000).toStringAsFixed(1)} km away';
}

IconData categoryIcon(String category) {
  switch (category) {
    case 'electronics':
      return Icons.smartphone;
    case 'wallet':
      return Icons.account_balance_wallet_outlined;
    case 'keys':
      return Icons.vpn_key_outlined;
    case 'documents':
      return Icons.badge_outlined;
    case 'bag':
      return Icons.backpack_outlined;
    case 'jewellery':
      return Icons.watch_outlined;
    case 'clothing':
      return Icons.checkroom_outlined;
    case 'books':
      return Icons.menu_book_outlined;
    case 'pet':
      return Icons.pets_outlined;
    default:
      return Icons.category_outlined;
  }
}

IconData handoverIcon(String handover) {
  switch (handover) {
    case 'left_there':
      return Icons.place_outlined;
    case 'police':
      return Icons.local_police_outlined;
    case 'desk':
      return Icons.support_agent_outlined;
    case 'kept':
      return Icons.back_hand_outlined;
    default:
      return Icons.help_outline;
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
  ));
}

class TypeBadge extends StatelessWidget {
  final String postType;
  const TypeBadge(this.postType, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = typeColor(postType);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(
        postType == 'found' ? 'FOUND' : 'LOST',
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11, letterSpacing: 0.6),
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  final String status;
  const StatusBadge(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    if (status == 'open') return const SizedBox.shrink();
    final (label, color) = switch (status) {
      'claimed' => ('Claimed', Colors.blue),
      'returned' => ('Returned', Colors.green),
      'hidden' => ('Under review', Colors.red),
      _ => (status, Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 11)),
    );
  }
}

class NetImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  final IconData placeholderIcon;
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.placeholderIcon = Icons.image_outlined});

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(placeholderIcon, color: Theme.of(context).colorScheme.outline),
    );
    if (url == null) return placeholder;
    return Image.network(
      url!,
      fit: fit,
      errorBuilder: (_, __, ___) => placeholder,
      loadingBuilder: (context, child, progress) => progress == null ? child : placeholder,
    );
  }
}

class PostCard extends StatelessWidget {
  final Post post;
  final VoidCallback onTap;
  final Widget? trailing;
  const PostCard({super.key, required this.post, required this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = <String>[
      if (post.distanceM != null) formatDistance(post.distanceM),
      timeAgo(post.createdAt),
    ].where((s) => s.isNotEmpty).join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 92,
                  height: 92,
                  child: NetImage(post.thumbnail, placeholderIcon: categoryIcon(post.category)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      TypeBadge(post.postType),
                      const SizedBox(width: 6),
                      StatusBadge(post.status),
                      const Spacer(),
                      if (trailing != null) trailing!,
                    ]),
                    const SizedBox(height: 6),
                    Text(post.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    if (post.landmark.isNotEmpty)
                      Row(children: [
                        Icon(Icons.place_outlined, size: 14, color: theme.colorScheme.outline),
                        const SizedBox(width: 2),
                        Expanded(
                          child: Text(post.landmark,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                        ),
                      ]),
                    if (post.isFound && post.handoverLabel.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(children: [
                          Icon(handoverIcon(post.handover), size: 14, color: theme.colorScheme.outline),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Text(post.handoverLabel,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                          ),
                        ]),
                      ),
                    const SizedBox(height: 6),
                    Row(children: [
                      Icon(post.hasVoted ? Icons.arrow_upward : Icons.arrow_upward_outlined,
                          size: 16, color: post.hasVoted ? theme.colorScheme.primary : theme.colorScheme.outline),
                      Text(' ${post.score}   ', style: theme.textTheme.bodySmall),
                      Icon(Icons.mode_comment_outlined, size: 15, color: theme.colorScheme.outline),
                      Text(' ${post.commentCount}', style: theme.textTheme.bodySmall),
                      const Spacer(),
                      Flexible(
                        child: Text(meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MessageView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  const MessageView({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(body!, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ]),
      ),
    );
  }
}

/// A one-field dialog that returns the text entered, or null if cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? hint,
  String? message,
  String confirm = 'Send',
  int maxLines = 3,
  bool required = true,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (message != null) ...[Text(message), const SizedBox(height: 12)],
        TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: maxLines,
          decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final text = controller.text.trim();
            if (required && text.isEmpty) return;
            Navigator.pop(context, text);
          },
          child: Text(confirm),
        ),
      ],
    ),
  );
}
