import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Thrown for any failed API call, with a message fit to show the user.
class ApiException implements Exception {
  final int? statusCode;
  final String message;
  final Map<String, dynamic> fieldErrors;

  ApiException(this.message, {this.statusCode, this.fieldErrors = const {}});

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

/// A rectangle to blur on a photo, as fractions (0..1) of its width/height.
class BlurRegion {
  final double x, y, w, h;
  const BlurRegion(this.x, this.y, this.w, this.h);

  Map<String, double> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
}

/// Everything needed to publish a new post.
class NewPost {
  String postType = 'found';
  String title = '';
  String description = '';
  String category = 'other';
  double? latitude;
  double? longitude;
  double? accuracyM;
  String landmark = '';
  DateTime occurredAt = DateTime.now();
  String handover = '';
  String handoverDetails = '';
  String verificationQuestion = '';
  final List<File> images = [];
  final List<List<BlurRegion>> blurRegions = [];
}

class ApiClient {
  String baseUrl;
  String? token;

  /// Called when the server says the saved token is no longer valid.
  void Function()? onUnauthorized;

  ApiClient(this.baseUrl, {this.token});

  static const _timeout = Duration(seconds: 30);

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final params = <String, String>{};
    query?.forEach((key, value) {
      if (value != null && value.toString().isNotEmpty) params[key] = value.toString();
    });
    return Uri.parse('$base$path').replace(queryParameters: params.isEmpty ? null : params);
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Token $token',
      };

  Future<dynamic> _send(Future<http.Response> Function() request) async {
    http.Response response;
    try {
      response = await request().timeout(_timeout);
    } on SocketException {
      throw ApiException("Can't reach the server at $baseUrl. Check your connection and the server address.");
    } on TimeoutException {
      throw ApiException('The server took too long to answer. Try again.');
    } on http.ClientException catch (e) {
      throw ApiException("Can't reach the server: ${e.message}");
    }
    return _decode(response.statusCode, response.bodyBytes);
  }

  dynamic _decode(int statusCode, List<int> bytes) {
    dynamic data;
    if (bytes.isNotEmpty) {
      try {
        data = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      } catch (_) {
        data = null; // e.g. an HTML error page from a proxy
      }
    }
    if (statusCode >= 200 && statusCode < 300) return data;

    if (statusCode == 401) onUnauthorized?.call();
    var message = 'Something went wrong (error $statusCode).';
    final fields = <String, dynamic>{};
    if (data is Map<String, dynamic>) {
      if (data['detail'] != null) {
        message = _flatten(data['detail']);
      } else if (data.isNotEmpty) {
        data.forEach((key, value) => fields[key] = _flatten(value));
        message = fields.values.first.toString();
      }
    } else if (statusCode == 429) {
      message = 'Too many requests. Please wait a minute and try again.';
    }
    throw ApiException(message, statusCode: statusCode, fieldErrors: fields);
  }

  static String _flatten(dynamic value) {
    if (value is List) return value.map(_flatten).join(' ');
    if (value is Map) return value.values.map(_flatten).join(' ');
    return value.toString();
  }

  Future<dynamic> _get(String path, [Map<String, dynamic>? query]) =>
      _send(() => http.get(_uri(path, query), headers: _headers));

  Future<dynamic> _post(String path, [Map<String, dynamic>? body]) => _send(() => http.post(
        _uri(path),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(body ?? {}),
      ));

  Future<dynamic> _patch(String path, Map<String, dynamic> body) => _send(() => http.patch(
        _uri(path),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ));

  Future<dynamic> _delete(String path) => _send(() => http.delete(_uri(path), headers: _headers));

  PagedResult<T> _page<T>(dynamic data, T Function(Map<String, dynamic>) parse) {
    final results = (data['results'] as List).map((e) => parse(e as Map<String, dynamic>)).toList();
    return PagedResult(results, data['next'] != null, (data['count'] as int?) ?? results.length);
  }

  // ---------------------------------------------------------------- auth ---

  Future<(String, AppUser)> login(String username, String password) async {
    final data = await _post('/api/auth/login/', {'username': username, 'password': password});
    return (data['token'] as String, AppUser.fromJson(data['user'] as Map<String, dynamic>));
  }

  Future<(String, AppUser)> register({
    required String username,
    required String email,
    required String password,
    String displayName = '',
  }) async {
    final data = await _post('/api/auth/register/', {
      'username': username,
      'email': email,
      'password': password,
      'display_name': displayName,
    });
    return (data['token'] as String, AppUser.fromJson(data['user'] as Map<String, dynamic>));
  }

  Future<AppUser> me() async => AppUser.fromJson(await _get('/api/auth/me/') as Map<String, dynamic>);

  Future<void> logout() async {
    try {
      await _post('/api/auth/logout/');
    } catch (_) {
      // Logging out locally is what matters.
    }
  }

  Future<AppMeta> meta() async => AppMeta.fromJson(await _get('/api/meta/') as Map<String, dynamic>);

  // --------------------------------------------------------------- posts ---

  Future<PagedResult<Post>> feed({
    double? lat,
    double? lng,
    double radiusKm = 5,
    String? type,
    String? category,
    String? query,
    String? sort,
    int page = 1,
  }) async {
    final data = await _get('/api/posts/', {
      'lat': lat,
      'lng': lng,
      'radius_km': lat == null ? null : radiusKm,
      'type': type,
      'category': category,
      'q': query,
      'sort': sort,
      'page': page,
    });
    return _page(data, Post.fromJson);
  }

  Future<List<Post>> mapPosts({
    required double west,
    required double south,
    required double east,
    required double north,
    String? type,
    String? category,
  }) async {
    final data = await _get('/api/posts/map/', {
      'bbox': '$west,$south,$east,$north',
      'type': type,
      'category': category,
    });
    return (data as List).map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Post> post(int id) async => Post.fromJson(await _get('/api/posts/$id/') as Map<String, dynamic>);

  Future<Post> createPost(NewPost draft) async {
    final request = http.MultipartRequest('POST', _uri('/api/posts/'))..headers.addAll(_headers);
    void field(String key, Object? value) {
      if (value != null && value.toString().isNotEmpty) request.fields[key] = value.toString();
    }

    field('post_type', draft.postType);
    field('title', draft.title.trim());
    field('description', draft.description.trim());
    field('category', draft.category);
    field('latitude', draft.latitude?.toStringAsFixed(7));
    field('longitude', draft.longitude?.toStringAsFixed(7));
    field('accuracy_m', draft.accuracyM?.toStringAsFixed(1));
    field('landmark', draft.landmark.trim());
    field('occurred_at', draft.occurredAt.toUtc().toIso8601String());
    if (draft.postType == 'found') {
      field('handover', draft.handover);
      field('handover_details', draft.handoverDetails.trim());
      field('verification_question', draft.verificationQuestion.trim());
    }
    if (draft.blurRegions.any((regions) => regions.isNotEmpty)) {
      field('blur_regions',
          jsonEncode(draft.blurRegions.map((regions) => regions.map((r) => r.toJson()).toList()).toList()));
    }
    for (final image in draft.images) {
      request.files.add(await http.MultipartFile.fromPath('images', image.path));
    }

    final data = await _send(() async {
      final streamed = await request.send();
      return http.Response.fromStream(streamed);
    });
    return Post.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deletePost(int id) => _delete('/api/posts/$id/');

  Future<(bool, int)> toggleVote(int postId) async {
    final data = await _post('/api/posts/$postId/vote/');
    return (data['has_voted'] as bool, data['score'] as int);
  }

  Future<void> resolve(int postId) => _post('/api/posts/$postId/resolve/');

  Future<void> renew(int postId) => _post('/api/posts/$postId/renew/');

  Future<String> report(int postId, String reason, String details) async {
    final data = await _post('/api/posts/$postId/report/', {'reason': reason, 'details': details});
    return (data['detail'] as String?) ?? 'Reported.';
  }

  Future<Post> editPost(int postId, Map<String, dynamic> changes) async =>
      Post.fromJson(await _patch('/api/posts/$postId/', changes) as Map<String, dynamic>);

  // ------------------------------------------------------------ comments ---

  Future<List<Comment>> comments(int postId) async {
    final data = await _get('/api/posts/$postId/comments/');
    return (data as List).map((e) => Comment.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Comment> addComment(int postId, String body, {int? parent}) async {
    final data = await _post('/api/posts/$postId/comments/', {'body': body, 'parent': parent});
    return Comment.fromJson(data as Map<String, dynamic>);
  }

  // -------------------------------------------------------------- claims ---

  Future<Claim> sendClaim(int postId, String answer, String message) async {
    final data = await _post('/api/posts/$postId/claims/', {'answer': answer, 'message': message});
    return Claim.fromJson(data as Map<String, dynamic>);
  }

  Future<List<Claim>> claimsForPost(int postId) async {
    final data = await _get('/api/posts/$postId/claims/');
    return (data as List).map((e) => Claim.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Claim> decideClaim(int claimId, {required bool approve, String response = ''}) async {
    final data = await _post('/api/claims/$claimId/decide/', {
      'decision': approve ? 'approve' : 'reject',
      'response': response,
    });
    return Claim.fromJson(data as Map<String, dynamic>);
  }

  Future<void> withdrawClaim(int claimId) => _post('/api/claims/$claimId/withdraw/');

  // ------------------------------------------------------------------ me ---

  Future<PagedResult<Post>> myPosts({int page = 1}) async =>
      _page(await _get('/api/me/posts/', {'page': page}), Post.fromJson);

  Future<PagedResult<Claim>> myClaims({int page = 1}) async =>
      _page(await _get('/api/me/claims/', {'page': page}), Claim.fromJson);
}
