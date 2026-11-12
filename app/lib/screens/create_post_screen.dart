import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'blur_editor_screen.dart';
import 'map_screen.dart';

/// Post a found or lost item. For found items the phone's location is read
/// the moment the photo is taken, then the finder can nudge the pin.
class CreatePostScreen extends StatefulWidget {
  final String postType; // found | lost
  const CreatePostScreen({super.key, required this.postType});

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final _form = GlobalKey<FormState>();
  final _draft = NewPost();
  final _picker = ImagePicker();
  final _map = MapController();
  bool _mapReady = false;

  final _title = TextEditingController();
  final _description = TextEditingController();
  final _landmark = TextEditingController();
  final _details = TextEditingController();
  final _question = TextEditingController();

  bool _locating = false;
  bool _pinMoved = false;
  String? _locationError;
  bool _submitting = false;
  Map<String, dynamic> _serverErrors = {};

  bool get _isFound => widget.postType == 'found';

  @override
  void initState() {
    super.initState();
    _draft.postType = widget.postType;
    // Lost posts start from where you are now; found posts wait for the photo.
    if (!_isFound) _captureLocation();
  }

  @override
  void dispose() {
    for (final c in [_title, _description, _landmark, _details, _question]) {
      c.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ location ---

  Future<void> _captureLocation() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final position = await LocationService.current();
      if (!mounted) return;
      setState(() {
        _draft.latitude = position.latitude;
        _draft.longitude = position.longitude;
        _draft.accuracyM = position.accuracy;
        _pinMoved = false;
      });
      if (_mapReady) _map.move(LatLng(position.latitude, position.longitude), 17);
    } on LocationException catch (e) {
      if (mounted) setState(() => _locationError = e.message);
    } catch (_) {
      if (mounted) setState(() => _locationError = "Couldn't read your location. Tap the map to place the pin.");
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _movePin(LatLng point) {
    setState(() {
      _draft.latitude = point.latitude;
      _draft.longitude = point.longitude;
      _draft.accuracyM = null; // placed by hand
      _pinMoved = true;
      _locationError = null;
    });
  }

  // -------------------------------------------------------------- photos ---

  Future<void> _addPhoto(ImageSource source) async {
    final max = context.read<Session>().meta?.maxImages ?? 5;
    if (_draft.images.length >= max) {
      showSnack(context, 'You can add up to $max photos.');
      return;
    }
    XFile? picked;
    try {
      picked = await _picker.pickImage(source: source, maxWidth: 2000, maxHeight: 2000, imageQuality: 85);
    } catch (_) {
      if (mounted) {
        showSnack(context, "Couldn't open the ${source == ImageSource.camera ? 'camera' : 'gallery'}.", error: true);
      }
      return;
    }
    if (picked == null || !mounted) return;
    final file = File(picked.path);
    final firstPhoto = _draft.images.isEmpty;
    setState(() {
      _draft.images.add(file);
      _draft.blurRegions.add([]);
    });
    // The location is captured the moment the first photo is taken.
    if (firstPhoto && !_pinMoved) {
      await _captureLocation();
      if (source == ImageSource.gallery && mounted) {
        showSnack(context, 'Photo from gallery: check the pin is where you found the item.');
      }
    }
    if (_draft.category == 'documents' && mounted) _editBlur(_draft.images.length - 1);
  }

  Future<void> _editBlur(int index) async {
    final regions = await Navigator.of(context).push<List<BlurRegion>>(MaterialPageRoute(
      builder: (_) => BlurEditorScreen(image: _draft.images[index], initial: _draft.blurRegions[index]),
    ));
    if (regions != null) setState(() => _draft.blurRegions[index] = regions);
  }

  void _removePhoto(int index) {
    setState(() {
      _draft.images.removeAt(index);
      _draft.blurRegions.removeAt(index);
    });
  }

  // -------------------------------------------------------------- submit ---

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _draft.occurredAt,
      firstDate: now.subtract(const Duration(days: 60)),
      lastDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_draft.occurredAt));
    if (time == null) return;
    var picked = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (picked.isAfter(now)) picked = now;
    setState(() => _draft.occurredAt = picked);
  }

  String? _clientCheck() {
    if (_isFound && _draft.images.isEmpty) return 'Add at least one photo of the item.';
    if (_draft.latitude == null) return 'Set the location: allow GPS or tap the map.';
    if (_isFound && _draft.handover.isEmpty) return 'Choose what you did with the item.';
    if (_isFound && _draft.category == 'documents' && !_draft.blurRegions.any((r) => r.isNotEmpty)) {
      return 'Blur ID or card numbers before posting documents. Tap the blur icon on the photo.';
    }
    return null;
  }

  Future<void> _submit() async {
    setState(() => _serverErrors = {});
    final formOk = _form.currentState!.validate();
    final problem = _clientCheck();
    if (!formOk || problem != null) {
      if (problem != null) showSnack(context, problem, error: true);
      return;
    }
    _draft
      ..title = _title.text
      ..description = _description.text
      ..landmark = _landmark.text
      ..handoverDetails = _details.text
      ..verificationQuestion = _question.text;

    setState(() => _submitting = true);
    try {
      await context.read<Session>().api.createPost(_draft);
      if (!mounted) return;
      showSnack(context, _isFound ? 'Posted. Thanks for helping!' : 'Posted. We hope it turns up soon.');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _serverErrors = e.fieldErrors);
      showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _err(String field) => _serverErrors[field]?.toString();

  // ------------------------------------------------------------------ UI ---

  @override
  Widget build(BuildContext context) {
    final meta = context.watch<Session>().meta;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_isFound ? 'Post a found item' : 'Post a lost item')),
      body: Form(
        key: _form,
        // A Column (not a lazy ListView) so the map widget is never disposed
        // while scrolled off-screen and its controller stays usable.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _section(_isFound ? '1. Photos' : '1. Photos (optional)',
                _isFound ? 'Take a clear photo. Your location is tagged when you take it.' : 'A photo of the item, if you have one.'),
            _photos(theme),
            if (_err('images') != null) _errorText(_err('images')!),
            if (_err('blur_regions') != null) _errorText(_err('blur_regions')!),
            const SizedBox(height: 20),
            _section(_isFound ? '2. Where you found it' : '2. Where you lost it',
                'Tap the map to move the pin if GPS is off.'),
            _locationPicker(theme),
            const SizedBox(height: 10),
            TextFormField(
              controller: _landmark,
              decoration: InputDecoration(
                labelText: _isFound ? 'Landmark (required)' : 'Landmark or area',
                hintText: 'e.g. Near Gate 2, Orion Mall food court',
                errorText: _err('landmark'),
              ),
              validator: (v) => _isFound && (v == null || v.trim().isEmpty) ? 'GPS is often off indoors; add a landmark' : null,
            ),
            const SizedBox(height: 20),
            _section('3. About the item', null),
            TextFormField(
              controller: _title,
              maxLength: 120,
              decoration: InputDecoration(
                labelText: 'Title',
                hintText: _isFound ? 'Black wallet near bus stop' : 'Lost: blue backpack',
                errorText: _err('title'),
              ),
              validator: (v) => (v == null || v.trim().length < 3) ? 'Give it a short title' : null,
            ),
            DropdownButtonFormField<String>(
              initialValue: _draft.category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: (meta?.categories ?? const [Choice('other', 'Other')])
                  .map((c) => DropdownMenuItem(value: c.value, child: Text(c.label)))
                  .toList(),
              onChanged: (v) => setState(() => _draft.category = v ?? 'other'),
            ),
            if (_isFound && _draft.category == 'documents')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Blur ID numbers, card numbers and addresses on every photo before posting.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _description,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: 'Description',
                hintText: _isFound
                    ? "Colour, brand, what's inside. Keep one detail back for your verification question."
                    : 'Colour, brand, marks, anything that helps a finder recognise it',
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: Text(_isFound ? 'When you found it' : 'When you lost it'),
              subtitle: Text(_formatWhen(_draft.occurredAt)),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _pickTime,
            ),
            if (_isFound) ...[
              const SizedBox(height: 12),
              _section('4. What did you do with it?', 'This tells the owner exactly where to go.'),
              ..._handoverOptions(meta, theme),
              if (_err('handover') != null) _errorText(_err('handover')!),
              if (_draft.handover == 'police' || _draft.handover == 'desk') ...[
                const SizedBox(height: 8),
                TextFormField(
                  controller: _details,
                  decoration: InputDecoration(
                    labelText: _draft.handover == 'police' ? 'Police station name' : 'Desk or office name',
                    hintText: _draft.handover == 'police' ? 'Rajajinagar Police Station' : 'Mall security, ground floor',
                    errorText: _err('handover_details'),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required so the owner knows where to go' : null,
                ),
              ],
              if (_draft.handover == 'kept') ...[
                const SizedBox(height: 8),
                TextFormField(
                  controller: _question,
                  decoration: InputDecoration(
                    labelText: 'Verification question',
                    hintText: "What's the phone wallpaper? What's inside the wallet?",
                    helperText: "Only the real owner should know the answer. Don't reveal it in the description.",
                    helperMaxLines: 2,
                    errorText: _err('verification_question'),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Needed to check claims' : null,
                ),
              ],
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              icon: _submitting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text(_submitting ? 'Posting...' : 'Post'),
            ),
            const SizedBox(height: 8),
            Text(
              'Photos are cleaned of hidden location data before they are stored.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ]),
        ),
      ),
    );
  }

  String _formatWhen(DateTime t) {
    final today = DateTime.now();
    final sameDay = t.year == today.year && t.month == today.month && t.day == today.day;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return sameDay ? 'Today, $hh:$mm' : '${t.day}/${t.month}/${t.year}, $hh:$mm';
  }

  Widget _section(String title, String? subtitle) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (subtitle != null) Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );

  Widget _errorText(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );

  Widget _photos(ThemeData theme) {
    return SizedBox(
      height: 112,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        for (var i = 0; i < _draft.images.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Stack(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(_draft.images[i], width: 112, height: 112, fit: BoxFit.cover),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: _roundIcon(Icons.close, () => _removePhoto(i)),
              ),
              Positioned(
                bottom: 2,
                right: 2,
                child: _roundIcon(
                  Icons.blur_on,
                  () => _editBlur(i),
                  highlight: _draft.blurRegions[i].isNotEmpty,
                ),
              ),
            ]),
          ),
        _addTile(Icons.photo_camera_outlined, 'Camera', () => _addPhoto(ImageSource.camera), theme),
        const SizedBox(width: 8),
        _addTile(Icons.photo_library_outlined, 'Gallery', () => _addPhoto(ImageSource.gallery), theme),
      ]),
    );
  }

  Widget _roundIcon(IconData icon, VoidCallback onTap, {bool highlight = false}) => Material(
        color: highlight ? Colors.green : Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(5), child: Icon(icon, size: 18, color: Colors.white)),
        ),
      );

  Widget _addTile(IconData icon, String label, VoidCallback onTap, ThemeData theme) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 100,
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 30, color: theme.colorScheme.primary),
            const SizedBox(height: 4),
            Text(label),
          ]),
        ),
      );

  Widget _locationPicker(ThemeData theme) {
    final hasPoint = _draft.latitude != null;
    final point = hasPoint ? LatLng(_draft.latitude!, _draft.longitude!) : const LatLng(12.9716, 77.5946);
    String status;
    if (_locating) {
      status = 'Getting your location...';
    } else if (_locationError != null) {
      status = _locationError!;
    } else if (!hasPoint) {
      status = _isFound ? 'Location will be tagged when you take the photo.' : 'Tap the map to set the place.';
    } else if (_pinMoved) {
      status = 'Pin placed by you.';
    } else {
      status = 'Tagged from GPS (about ${_draft.accuracyM?.round() ?? '?'} m accuracy).';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 200,
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: point,
              initialZoom: hasPoint ? 17 : 13,
              onMapReady: () => _mapReady = true,
              onTap: (_, latLng) => _movePin(latLng),
            ),
            children: [
              ...baseMapLayers(),
              if (hasPoint)
                MarkerLayer(markers: [
                  Marker(
                    point: point,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    child: Icon(Icons.location_on, size: 44, color: typeColor(widget.postType)),
                  ),
                ]),
              osmAttribution(),
            ],
          ),
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Icon(
          _locationError != null ? Icons.location_off_outlined : Icons.my_location,
          size: 16,
          color: _locationError != null ? theme.colorScheme.error : theme.colorScheme.outline,
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(status, style: theme.textTheme.bodySmall)),
        TextButton(onPressed: _locating ? null : _captureLocation, child: const Text('Use my location')),
      ]),
    ]);
  }

  List<Widget> _handoverOptions(AppMeta? meta, ThemeData theme) {
    final options = meta?.handoverOptions ??
        const [
          Choice('left_there', 'Left it where I found it'),
          Choice('police', 'Handed it to the police'),
          Choice('desk', 'Gave it to security / a lost-and-found desk'),
          Choice('kept', 'Kept it with me'),
        ];
    return [
      for (final option in options)
        Card(
          margin: const EdgeInsets.only(bottom: 6),
          color: _draft.handover == option.value ? theme.colorScheme.secondaryContainer : null,
          child: ListTile(
            leading: Icon(handoverIcon(option.value)),
            title: Text(option.label),
            trailing: Icon(
              _draft.handover == option.value ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: _draft.handover == option.value ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
            subtitle: _draft.handover == option.value && option.guidance.isNotEmpty
                ? Text('Owner will see: ${option.guidance}', style: theme.textTheme.bodySmall)
                : null,
            onTap: () => setState(() => _draft.handover = option.value),
          ),
        ),
    ];
  }
}
