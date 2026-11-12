import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../api.dart';

/// Drag boxes over anything private (ID numbers, card numbers, addresses,
/// faces). The server blurs those areas before the photo is ever stored, so
/// the original never leaves the finder's phone unblurred on the server.
class BlurEditorScreen extends StatefulWidget {
  final File image;
  final List<BlurRegion> initial;
  const BlurEditorScreen({super.key, required this.image, this.initial = const []});

  @override
  State<BlurEditorScreen> createState() => _BlurEditorScreenState();
}

class _BlurEditorScreenState extends State<BlurEditorScreen> {
  double? _aspect;
  late final List<Rect> _boxes = widget.initial.map((r) => Rect.fromLTWH(r.x, r.y, r.w, r.h)).toList();
  Offset? _start;
  Rect? _drawing;

  @override
  void initState() {
    super.initState();
    _readSize();
  }

  Future<void> _readSize() async {
    final bytes = await widget.image.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _aspect = frame.image.width / frame.image.height);
    frame.image.dispose();
  }

  Offset _fraction(Offset local, Size size) =>
      Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));

  void _done() {
    Navigator.pop(
      context,
      _boxes.map((r) => BlurRegion(r.left, r.top, r.width, r.height)).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Hide private details'),
        actions: [TextButton(onPressed: _done, child: const Text('Done'))],
      ),
      body: Column(children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Drag a box over ID numbers, card numbers, addresses or faces. Those areas are blurred before the photo is posted.',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: Center(
            child: _aspect == null
                ? const CircularProgressIndicator()
                : AspectRatio(
                    aspectRatio: _aspect!,
                    child: LayoutBuilder(builder: (context, constraints) {
                      final size = constraints.biggest;
                      return GestureDetector(
                        onPanStart: (d) => setState(() {
                          _start = _fraction(d.localPosition, size);
                          _drawing = Rect.fromPoints(_start!, _start!);
                        }),
                        onPanUpdate: (d) => setState(() {
                          _drawing = Rect.fromPoints(_start!, _fraction(d.localPosition, size));
                        }),
                        onPanEnd: (_) => setState(() {
                          final box = _drawing;
                          if (box != null && box.width > 0.02 && box.height > 0.02) _boxes.add(box);
                          _drawing = null;
                          _start = null;
                        }),
                        child: Stack(fit: StackFit.expand, children: [
                          Image.file(widget.image, fit: BoxFit.fill),
                          CustomPaint(painter: _BoxPainter(_boxes, _drawing)),
                        ]),
                      );
                    }),
                  ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              TextButton.icon(
                onPressed: _boxes.isEmpty ? null : () => setState(() => _boxes.removeLast()),
                icon: const Icon(Icons.undo),
                label: const Text('Undo'),
              ),
              TextButton.icon(
                onPressed: _boxes.isEmpty ? null : () => setState(_boxes.clear),
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear'),
              ),
              Text('${_boxes.length} area${_boxes.length == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.white70)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _BoxPainter extends CustomPainter {
  final List<Rect> boxes;
  final Rect? drawing;
  _BoxPainter(this.boxes, this.drawing);

  Rect _scale(Rect r, Size size) =>
      Rect.fromLTWH(r.left * size.width, r.top * size.height, r.width * size.width, r.height * size.height);

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = Colors.black.withValues(alpha: 0.75);
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final box in boxes) {
      final rect = _scale(box, size);
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, border);
    }
    if (drawing != null) {
      final rect = _scale(drawing!, size);
      canvas.drawRect(rect, Paint()..color = Colors.white.withValues(alpha: 0.25));
      canvas.drawRect(rect, border);
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => true;
}
