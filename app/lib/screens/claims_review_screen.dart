import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'chat_screen.dart';

/// The finder compares each claimant's answer with what they know about the
/// item, then approves one (with a meetup message) or rejects.
class ClaimsReviewScreen extends StatefulWidget {
  final Post post;
  const ClaimsReviewScreen({super.key, required this.post});

  @override
  State<ClaimsReviewScreen> createState() => _ClaimsReviewScreenState();
}

class _ClaimsReviewScreenState extends State<ClaimsReviewScreen> {
  List<Claim>? _claims;
  String? _error;

  ApiClient get _api => context.read<Session>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final claims = await _api.claimsForPost(widget.post.id);
      if (mounted) setState(() => _claims = claims);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _approve(Claim claim) async {
    final response = await promptText(
      context,
      title: 'Approve ${claim.claimant.displayName}?',
      message: 'Tell them where and when to collect the item. Only they will see this.',
      hint: 'e.g. Gate 2 of the metro station, tomorrow 5 pm. Call me on ...',
      confirm: 'Approve',
      maxLines: 4,
    );
    if (response == null) return;
    await _decide(claim, approve: true, response: response);
  }

  Future<void> _reject(Claim claim) async {
    final response = await promptText(
      context,
      title: 'Reject this claim?',
      message: 'Optionally tell them why.',
      hint: "The answer didn't match",
      confirm: 'Reject',
      required: false,
    );
    if (response == null) return;
    await _decide(claim, approve: false, response: response);
  }

  Future<void> _revoke(Claim claim) async {
    final reason = await promptText(
      context,
      title: 'Cancel approval for ${claim.claimant.displayName}?',
      message: "They'll lose the exact location and the item opens for claims again. "
          "They won't be able to claim it a second time.",
      hint: "e.g. Didn't turn up / the answer was a lucky guess",
      confirm: 'Cancel approval',
      required: false,
    );
    if (reason == null) return;
    try {
      await _api.revokeClaim(claim.id, reason: reason);
      if (mounted) showSnack(context, 'Approval cancelled. You can approve someone else now.');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  /// Ask every waiting claimant one more question, privately in each chat,
  /// so two people who gave the same answer can be told apart.
  Future<void> _followUp() async {
    final question = await promptText(
      context,
      title: 'Ask a follow-up question',
      message: 'Each person with a waiting claim gets it privately in Messages, so they can\'t copy each other. '
          'Ask about something not visible in your photos.',
      hint: 'e.g. What\'s written on the back? What else was inside?',
      confirm: 'Ask',
    );
    if (question == null) return;
    try {
      final message = await _api.askFollowUp(widget.post.id, question);
      if (mounted) showSnack(context, message);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  Future<void> _decide(Claim claim, {required bool approve, required String response}) async {
    try {
      await _api.decideClaim(claim.id, approve: approve, response: response);
      if (mounted) showSnack(context, approve ? 'Approved. Now meet them somewhere public.' : 'Claim rejected.');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final claims = _claims;
    final anyApproved = claims?.any((c) => c.isApproved) ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Claims')),
      body: _error != null
          ? MessageView(icon: Icons.error_outline, title: _error!, actionLabel: 'Try again', onAction: _load)
          : claims == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.all(16), children: [
                    Card(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Your question', style: theme.textTheme.labelMedium),
                          Text(widget.post.verificationQuestion, style: theme.textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Text(
                            'Approve only someone whose answer matches. Hand over in a public place, '
                            'and never ask for or send money.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ]),
                      ),
                    ),
                    if (claims.any((c) => c.isPending) && !anyApproved) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.quiz_outlined),
                        label: const Text('Ask a follow-up question'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                        onPressed: _followUp,
                      ),
                      if (claims.where((c) => c.isPending).length > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Several people answered? Ask a second question only the owner could know, chat with them, '
                            'or hand the item over at a police station where they can check proof.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                    ],
                    const SizedBox(height: 12),
                    if (claims.isEmpty)
                      const MessageView(
                        icon: Icons.inbox_outlined,
                        title: 'No claims yet',
                        body: "When someone says it's theirs, their answer shows up here.",
                      ),
                    ...claims.map((claim) => _claimCard(claim, anyApproved)),
                  ]),
                ),
    );
  }

  Widget _claimCard(Claim claim, bool anyApproved) {
    final theme = Theme.of(context);
    final (statusColor, statusLabel) = switch (claim.status) {
      'approved' => (Colors.green, 'APPROVED'),
      'rejected' => (Colors.red, 'REJECTED'),
      'revoked' => (Colors.grey, 'APPROVAL CANCELLED'),
      _ => (Colors.orange, 'WAITING'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(child: Text(claim.claimant.displayName.characters.first.toUpperCase())),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(claim.claimant.displayName, style: theme.textTheme.titleSmall),
                Text(timeAgo(claim.createdAt), style: theme.textTheme.bodySmall),
              ]),
            ),
            Text(statusLabel,
                style: theme.textTheme.labelSmall?.copyWith(color: statusColor, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          Text('Their answer', style: theme.textTheme.labelMedium),
          Text(claim.answer, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          if (claim.message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Message', style: theme.textTheme.labelMedium),
            Text(claim.message),
          ],
          if (claim.finderResponse.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Your reply', style: theme.textTheme.labelMedium),
            Text(claim.finderResponse),
          ],
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton.icon(
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Message'),
              onPressed: () => openChatAbout(context, widget.post, withUser: claim.claimant),
            ),
            if (claim.isPending) ...[
              const SizedBox(width: 4),
              TextButton(onPressed: () => _reject(claim), child: const Text('Reject')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: anyApproved ? null : () => _approve(claim),
                child: const Text('Approve'),
              ),
            ],
          ]),
          if (claim.isApproved && widget.post.status != 'returned') ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.undo),
                label: const Text('Cancel approval'),
                onPressed: () => _revoke(claim),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
