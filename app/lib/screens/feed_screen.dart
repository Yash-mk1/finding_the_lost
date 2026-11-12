import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'post_detail_screen.dart';

/// The Reddit-style feed: posts near you, newest or most upvoted first.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => FeedScreenState();
}

class FeedScreenState extends State<FeedScreen> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;

  final List<Post> _posts = [];
  int _page = 1;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;

  double? _lat, _lng;
  String? _locationNote;

  String? _type; // null = all
  String? _category;
  String _sort = 'near';
  double _radiusKm = 5;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _loadMore();
    });
    _locate().then((_) => refresh());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _locate() async {
    try {
      final position = await LocationService.current();
      _lat = position.latitude;
      _lng = position.longitude;
      _locationNote = null;
    } on LocationException catch (e) {
      final last = await LocationService.lastKnown();
      _lat = last?.latitude;
      _lng = last?.longitude;
      _locationNote = last == null ? '${e.message} Showing newest posts everywhere.' : 'Using your last known location.';
    } catch (_) {
      _locationNote = "Couldn't get your location. Showing newest posts everywhere.";
    }
  }

  Future<void> refresh() async {
    setState(() {
      _posts.clear();
      _page = 1;
      _hasMore = true;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    final api = context.read<Session>().api;
    try {
      final page = await api.feed(
        lat: _lat,
        lng: _lng,
        radiusKm: _radiusKm,
        type: _type,
        category: _category,
        query: _search.text.trim(),
        sort: _lat == null && _sort == 'near' ? 'new' : _sort,
        page: _page,
      );
      if (!mounted) return;
      setState(() {
        _posts.addAll(page.results);
        _hasMore = page.hasMore;
        _page += 1;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), refresh);
  }

  Future<void> _openFilters() async {
    final meta = context.read<Session>().meta;
    String? category = _category;
    String sort = _sort;
    double radius = _radiusKm;
    final apply = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Sort by', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'near', label: Text('Nearest'), icon: Icon(Icons.near_me_outlined)),
                  ButtonSegment(value: 'new', label: Text('Newest'), icon: Icon(Icons.schedule)),
                  ButtonSegment(value: 'top', label: Text('Top'), icon: Icon(Icons.arrow_upward)),
                ],
                selected: {sort},
                onSelectionChanged: (s) => setSheet(() => sort = s.first),
              ),
              const SizedBox(height: 20),
              Text('Within ${radius.round()} km of you', style: Theme.of(context).textTheme.titleSmall),
              Slider(
                value: radius,
                min: 1,
                max: 100,
                divisions: 99,
                label: '${radius.round()} km',
                onChanged: (v) => setSheet(() => radius = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('All categories')),
                  ...?meta?.categories.map((c) => DropdownMenuItem<String?>(value: c.value, child: Text(c.label))),
                ],
                onChanged: (v) => setSheet(() => category = v),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                child: const Text('Apply'),
              ),
            ]),
          ),
        ),
      ),
    );
    if (apply == true) {
      setState(() {
        _category = category;
        _sort = sort;
        _radiusKm = radius;
      });
      refresh();
    }
  }

  Future<void> _open(Post post) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: post.id)));
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Finding the Lost'),
        actions: [
          IconButton(
            tooltip: 'Update my location',
            icon: const Icon(Icons.my_location),
            onPressed: () async {
              await _locate();
              refresh();
            },
          ),
          IconButton(tooltip: 'Filters', icon: const Icon(Icons.tune), onPressed: _openFilters),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(108),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(children: [
              TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search: wallet, keys, Gate 2...',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
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
                    refresh();
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _locate();
          await refresh();
        },
        child: _buildList(theme),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_error != null && _posts.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 80),
        MessageView(
          icon: Icons.cloud_off_outlined,
          title: "Couldn't load posts",
          body: _error,
          actionLabel: 'Try again',
          onAction: refresh,
        ),
      ]);
    }
    if (!_loading && _posts.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 80),
        MessageView(
          icon: Icons.inventory_2_outlined,
          title: 'Nothing here yet',
          body: 'No posts match. Try a bigger distance in filters, or be the first to post.',
        ),
      ]);
    }
    final filters = [
      if (_category != null) context.read<Session>().meta?.categoryLabel(_category!) ?? _category!,
      if (_lat != null) 'within ${_radiusKm.round()} km',
      switch (_sort) { 'top' => 'top first', 'new' => 'newest first', _ => 'nearest first' },
    ].join(' · ');

    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: _posts.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_locationNote != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    Icon(Icons.location_off_outlined, size: 16, color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_locationNote!, style: theme.textTheme.bodySmall)),
                    TextButton(onPressed: LocationService.openSettings, child: const Text('Settings')),
                  ]),
                ),
              Text(filters, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
            ]),
          );
        }
        if (index == _posts.length + 1) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : _hasMore
                      ? const SizedBox.shrink()
                      : Text("You're all caught up", style: theme.textTheme.bodySmall),
            ),
          );
        }
        final post = _posts[index - 1];
        return PostCard(post: post, onTap: () => _open(post));
      },
    );
  }
}
