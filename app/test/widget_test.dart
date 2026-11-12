import 'package:test/test.dart';

import '../lib/models.dart';
import '../lib/widgets.dart';

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
}
