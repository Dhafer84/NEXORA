import 'package:flutter/material.dart';

import '../theme.dart';

/// The NEXORA mark: a geometric N with rounded ends on a lavender disc.
/// Source: `design/nexora_mark.svg` (24 × 24 grid), also drawn natively for
/// the Android bubble and shortcut icons.
class NexoraMark extends StatelessWidget {
  const NexoraMark({super.key, this.size = 36, this.semanticLabel});

  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final mark = CustomPaint(
      size: Size.square(size),
      painter: const _MarkPainter(),
    );
    return semanticLabel == null
        ? ExcludeSemantics(child: mark)
        : Semantics(label: semanticLabel, image: true, child: mark);
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide / 24;
    canvas.drawCircle(
      Offset(12 * unit, 12 * unit),
      12 * unit,
      Paint()..color = NexoraPalette.lavender,
    );
    final n = Path()
      ..moveTo(7.6 * unit, 16.6 * unit)
      ..lineTo(7.6 * unit, 7.4 * unit)
      ..lineTo(16.4 * unit, 16.6 * unit)
      ..lineTo(16.4 * unit, 7.4 * unit);
    canvas.drawPath(
      n,
      Paint()
        ..color = NexoraPalette.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2 * unit
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}
