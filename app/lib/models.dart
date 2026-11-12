// Plain data classes for what the Findit API returns.

DateTime? _date(dynamic value) => value == null ? null : DateTime.tryParse(value as String)?.toLocal();

double? _double(dynamic value) => value == null ? null : (value as num).toDouble();

class Author {
  final int id;
  final String username;
  final String displayName;

  Author({required this.id, required this.username, required this.displayName});

  factory Author.fromJson(Map<String, dynamic> json) => Author(
        id: json['id'] as int,
        username: json['username'] as String,
        displayName: (json['display_name'] as String?) ?? json['username'] as String,
      );
}

class AppUser {
  final int id;
  final String username;
  final String email;
  final String displayName;

  AppUser({required this.id, required this.username, required this.email, required this.displayName});

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as int,
        username: json['username'] as String,
        email: (json['email'] as String?) ?? '',
        displayName: ((json['display_name'] as String?) ?? '').isEmpty
            ? json['username'] as String
            : json['display_name'] as String,
      );
}

class PostImage {
  final int id;
  final String url;
  final int width;
  final int height;

  PostImage({required this.id, required this.url, required this.width, required this.height});

  factory PostImage.fromJson(Map<String, dynamic> json) => PostImage(
        id: json['id'] as int,
        url: json['url'] as String,
        width: (json['width'] as int?) ?? 0,
        height: (json['height'] as int?) ?? 0,
      );
}

class Claim {
  final int id;
  final int postId;
  final String postTitle;
  final Author claimant;
  final String answer;
  final String message;
  final String status; // pending | approved | rejected | revoked
  final String finderResponse;
  final DateTime? createdAt;
  final DateTime? decidedAt;

  Claim({
    required this.id,
    required this.postId,
    required this.postTitle,
    required this.claimant,
    required this.answer,
    required this.message,
    required this.status,
    required this.finderResponse,
    this.createdAt,
    this.decidedAt,
  });

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRevoked => status == 'revoked';

  factory Claim.fromJson(Map<String, dynamic> json) => Claim(
        id: json['id'] as int,
        postId: json['post_id'] as int,
        postTitle: (json['post_title'] as String?) ?? '',
        claimant: Author.fromJson(json['claimant'] as Map<String, dynamic>),
        answer: (json['answer'] as String?) ?? '',
        message: (json['message'] as String?) ?? '',
        status: json['status'] as String,
        finderResponse: (json['finder_response'] as String?) ?? '',
        createdAt: _date(json['created_at']),
        decidedAt: _date(json['decided_at']),
      );
}

class Post {
  final int id;
  final String postType; // found | lost
  final String title;
  final String description;
  final String category;
  final String categoryLabel;
  final String status; // open | claimed | returned | hidden
  final double latitude;
  final double longitude;
  final bool locationIsApproximate;
  final double? approxRadiusM;
  final int? distanceM;
  final String landmark;
  final DateTime? occurredAt;
  final String handover;
  final String handoverLabel;
  final int score;
  final int commentCount;
  final bool hasVoted;
  final String? thumbnail;
  final Author author;
  final int authorReturnedCount;
  final bool isOwner;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final int pendingClaims;

  // Detail-only fields (empty/null in list responses).
  final List<PostImage> images;
  final String handoverDetails;
  final String verificationQuestion;
  final String guidance;
  final bool claimsEnabled;
  final double? accuracyM;
  final Claim? myClaim;
  final int? pendingClaimCount;

  Post({
    required this.id,
    required this.postType,
    required this.title,
    required this.description,
    required this.category,
    required this.categoryLabel,
    required this.status,
    required this.latitude,
    required this.longitude,
    required this.locationIsApproximate,
    required this.approxRadiusM,
    required this.distanceM,
    required this.landmark,
    required this.occurredAt,
    required this.handover,
    required this.handoverLabel,
    required this.score,
    required this.commentCount,
    required this.hasVoted,
    required this.thumbnail,
    required this.author,
    required this.authorReturnedCount,
    required this.isOwner,
    required this.createdAt,
    required this.expiresAt,
    required this.pendingClaims,
    required this.images,
    required this.handoverDetails,
    required this.verificationQuestion,
    required this.guidance,
    required this.claimsEnabled,
    required this.accuracyM,
    required this.myClaim,
    required this.pendingClaimCount,
  });

  bool get isFound => postType == 'found';
  bool get isOpen => status == 'open';

  factory Post.fromJson(Map<String, dynamic> json) => Post(
        id: json['id'] as int,
        postType: json['post_type'] as String,
        title: json['title'] as String,
        description: (json['description'] as String?) ?? '',
        category: json['category'] as String,
        categoryLabel: (json['category_label'] as String?) ?? json['category'] as String,
        status: json['status'] as String,
        latitude: _double(json['latitude'])!,
        longitude: _double(json['longitude'])!,
        locationIsApproximate: (json['location_is_approximate'] as bool?) ?? false,
        approxRadiusM: _double(json['approx_radius_m']),
        distanceM: json['distance_m'] as int?,
        landmark: (json['landmark'] as String?) ?? '',
        occurredAt: _date(json['occurred_at']),
        handover: (json['handover'] as String?) ?? '',
        handoverLabel: (json['handover_label'] as String?) ?? '',
        score: (json['score'] as int?) ?? 0,
        commentCount: (json['comment_count'] as int?) ?? 0,
        hasVoted: (json['has_voted'] as bool?) ?? false,
        thumbnail: json['thumbnail'] as String?,
        author: Author.fromJson(json['author'] as Map<String, dynamic>),
        authorReturnedCount: (json['author_returned_count'] as int?) ?? 0,
        isOwner: (json['is_owner'] as bool?) ?? false,
        createdAt: _date(json['created_at']),
        expiresAt: _date(json['expires_at']),
        pendingClaims: (json['pending_claims'] as int?) ?? 0,
        images: ((json['images'] as List?) ?? const [])
            .map((e) => PostImage.fromJson(e as Map<String, dynamic>))
            .toList(),
        handoverDetails: (json['handover_details'] as String?) ?? '',
        verificationQuestion: (json['verification_question'] as String?) ?? '',
        guidance: (json['guidance'] as String?) ?? '',
        claimsEnabled: (json['claims_enabled'] as bool?) ?? false,
        accuracyM: _double(json['accuracy_m']),
        myClaim: json['my_claim'] == null ? null : Claim.fromJson(json['my_claim'] as Map<String, dynamic>),
        pendingClaimCount: json['pending_claim_count'] as int?,
      );
}

class Comment {
  final int id;
  final int? parent;
  final Author author;
  final bool isPostAuthor;
  final String body;
  final DateTime? createdAt;

  Comment({
    required this.id,
    required this.parent,
    required this.author,
    required this.isPostAuthor,
    required this.body,
    required this.createdAt,
  });

  factory Comment.fromJson(Map<String, dynamic> json) => Comment(
        id: json['id'] as int,
        parent: json['parent'] as int?,
        author: Author.fromJson(json['author'] as Map<String, dynamic>),
        isPostAuthor: (json['is_post_author'] as bool?) ?? false,
        body: json['body'] as String,
        createdAt: _date(json['created_at']),
      );
}

class Choice {
  final String value;
  final String label;
  final String guidance;

  const Choice(this.value, this.label, [this.guidance = '']);

  factory Choice.fromJson(Map<String, dynamic> json) =>
      Choice(json['value'] as String, json['label'] as String, (json['guidance'] as String?) ?? '');
}

class AppMeta {
  final List<Choice> categories;
  final List<Choice> handoverOptions;
  final List<Choice> reportReasons;
  final int approxRadiusM;
  final int maxImages;
  final int postLifetimeDays;

  AppMeta({
    required this.categories,
    required this.handoverOptions,
    required this.reportReasons,
    required this.approxRadiusM,
    required this.maxImages,
    required this.postLifetimeDays,
  });

  factory AppMeta.fromJson(Map<String, dynamic> json) {
    List<Choice> list(String key) =>
        ((json[key] as List?) ?? const []).map((e) => Choice.fromJson(e as Map<String, dynamic>)).toList();
    return AppMeta(
      categories: list('categories'),
      handoverOptions: list('handover_options'),
      reportReasons: list('report_reasons'),
      approxRadiusM: (json['approx_radius_m'] as int?) ?? 250,
      maxImages: (json['max_images'] as int?) ?? 5,
      postLifetimeDays: (json['post_lifetime_days'] as int?) ?? 30,
    );
  }

  String categoryLabel(String value) =>
      categories.firstWhere((c) => c.value == value, orElse: () => Choice(value, value)).label;

  Choice? handover(String value) {
    for (final option in handoverOptions) {
      if (option.value == value) return option;
    }
    return null;
  }
}

class PagedResult<T> {
  final List<T> results;
  final bool hasMore;
  final int count;

  PagedResult(this.results, this.hasMore, this.count);
}
