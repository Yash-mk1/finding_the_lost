import 'package:finding_the_lost/api.dart';
import 'package:finding_the_lost/models.dart';
import 'package:finding_the_lost/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('distance labels', () {
    expect(formatDistance(450), '450 m away');
    expect(formatDistance(2350), '2.4 km away');
    expect(formatDistance(null), '');
  });

  test('post parses API JSON', () {
    final post = Post.fromJson({
      'id': 1,
      'post_type': 'found',
      'title': 'Black wallet',
      'category': 'wallet',
      'status': 'open',
      'latitude': 12.97,
      'longitude': 77.59,
      'location_is_approximate': true,
      'approx_radius_m': 250,
      'distance_m': 400,
      'handover': 'kept',
      'author': {'id': 2, 'username': 'asha', 'display_name': 'Asha'},
      'created_at': '2026-11-12T16:12:57+05:30',
    });
    expect(post.isFound, isTrue);
    expect(post.approxRadiusM, 250);
    expect(post.author.displayName, 'Asha');
    expect(post.images, isEmpty);
  });

  test('server address clean-up and encryption warning', () {
    expect(ApiClient.normalizeBase(' 192.168.1.20:8000/ '), 'http://192.168.1.20:8000');
    expect(ApiClient.normalizeBase('https://abc.trycloudflare.com/'), 'https://abc.trycloudflare.com');
    expect(ApiClient.isUnencryptedPublic('http://192.168.1.20:8000'), isFalse);
    expect(ApiClient.isUnencryptedPublic('http://10.0.2.2:8000'), isFalse);
    expect(ApiClient.isUnencryptedPublic('https://abc.trycloudflare.com'), isFalse);
    expect(ApiClient.isUnencryptedPublic('http://abc.trycloudflare.com'), isTrue);
    expect(ApiClient.isUnencryptedPublic('http://49.36.1.2:8000'), isTrue);
  });

  test('email code details parse from the server reply', () {
    final pending = PendingVerification.fromJson({
      'detail': 'Confirm your email to log in.',
      'code': 'email_unverified',
      'username': 'asha',
      'email_hint': 'a***@gmail.com',
      'resend_in': 42,
    });
    expect(pending.username, 'asha');
    expect(pending.emailHint, 'a***@gmail.com');
    expect(pending.resendIn, 42);
    expect(pending.emailFailed, isFalse);
  });
}
