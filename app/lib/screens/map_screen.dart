import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'post_detail_screen.dart';

const _bengaluru = LatLng(12.9716, 77.5946);

/// Tile layer + attribution shared by every map in the app.
List<Widget> baseMapLayers() => [
      TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'com.findingthelost.app',
      ),
    ];

Widget osmAttribution() => RichAttributionWidget(
      attributions: [TextSourceAttribution('OpenStreetMap contributors')],
    );

/// A pin for one post: green for found, orange for lost.
Marker postMarker(Post post, {VoidCallback? onTap}) => Marker(
      point: LatLng(post.latitude, post.longitude),
      width: 44,
      height: 44,
      alignment: Alignment.topCenter,
      child: GestureDetector(
        onTap: onTap,
        child: Icon(
          post.isFound ? Icons.location_on : Icons.location_searching,
          size: 44,
          color: typeColor(post.postType),
          shadows: const [Shadow(blurRadius: 4, color: Colors.black38)],
        ),
      ),
    );

/// The shaded circle for "kept it with me" posts whose exact spot is hidden.
CircleMarker? approxCircle(Post post) {
  if (!post.locationIsApproximate || post.approxRadiusM == null) return null;
  final color = typeColor(post.postType);
  return CircleMarker(
    point: LatLng(post.latitude, post.longitude),
    radius: post.approxRadiusM!,
    useRadiusInMeter: true,
    color: color.withValues(alpha: 0.15),
    borderColor: color.withValues(alpha: 0.6),
    borderStrokeWidth: 1.5,
  );
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _controller = MapController();
  Timer? _debounce;
  List<Post> _posts = [];
  LatLng? _me;
  String? _type;
  bool _loading = false;
  bool _mapReady = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _centreOnMe(initial: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _centreOnMe({bool initial = false}) async {
    try {
      final position = initial ? await LocationService.quick() : await LocationService.current();
      _me = LatLng(position.latitude, position.longitude);
      if (mounted) setState(() {});
      if (_mapReady) {
        _controller.move(_me!, 15);
        _scheduleLoad();
      }
    } on LocationException catch (e) {
      if (!initial && mounted) showSnack(context, e.message, error: true);
    } catch (_) {
      // Map still works without a location.
    }
  }

  void _scheduleLoad() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _load);
  }

  Future<void> _load() async {
    if (!_mapReady || !mounted) return;
    final bounds = _controller.camera.visibleBounds;
    setState(() => _loading = true);
    try {
      final posts = await context.read<Session>().api.mapPosts(
            west: bounds.west,
            south: bounds.south,
            east: bounds.east,
            north: bounds.north,
            type: _type,
          );
      if (mounted) {
        setState(() {
          _posts = posts;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showPost(Post post) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            PostCard(
              post: post,
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: post.id)))
                    .then((_) => _scheduleLoad());
              },
            ),
            if (post.locationIsApproximate)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Text(
                  'The finder kept this item, so only the approximate area is shown.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final circles = _posts.map(approxCircle).whereType<CircleMarker>().toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<String?>(
                segments: const [
                  ButtonSegment(value: null, label: Text('All')),
                  ButtonSegment(value: 'found', label: Text('Found')),
                  ButtonSegment(value: 'lost', label: Text('Lost')),
                ],
                selected: {_type},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  setState(() => _type = s.first);
                  _load();
                },
              ),
            ),
          ),
        ),
      ),
      body: Stack(children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: _me ?? _bengaluru,
            initialZoom: 14,
            onMapReady: () {
              _mapReady = true;
              if (_me != null) _controller.move(_me!, 15);
              _scheduleLoad();
            },
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture) _scheduleLoad();
            },
          ),
          children: [
            ...baseMapLayers(),
            CircleLayer(circles: circles),
            MarkerLayer(markers: [
              if (_me != null)
                Marker(
                  point: _me!,
                  width: 22,
                  height: 22,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                    ),
                  ),
                ),
              ..._posts.map((post) => postMarker(post, onTap: () => _showPost(post))),
            ]),
            osmAttribution(),
          ],
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ),
          ),
        Positioned(
          left: 12,
          bottom: 24,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.location_on, color: kFoundColor, size: 18),
                const Text(' Found   '),
                Icon(Icons.location_searching, color: kLostColor, size: 18),
                const Text(' Lost'),
              ]),
            ),
          ),
        ),
      ]),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 72),
        child: FloatingActionButton.small(
          heroTag: 'map-locate',
          tooltip: 'My location',
          onPressed: _centreOnMe,
          child: const Icon(Icons.my_location),
        ),
      ),
    );
  }
}
