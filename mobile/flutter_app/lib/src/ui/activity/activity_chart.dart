import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../activity/activity_models.dart';
import '../../activity/activity_stats.dart';
import '../theme.dart';

enum ChartKind { bars, line }

final _short = DateFormat('d/M', 'fr_FR');
final _long = DateFormat('EEE d MMM', 'fr_FR');

String shortDay(DayKey day) => _short.format(parseDay(day));
String longDay(DayKey day) => _long.format(parseDay(day));

/// One value per day. Missing days are marked as such (never drawn as 0),
/// partial days are drawn lighter. Touching or dragging selects a day; the
/// whole chart is described by [summary] for screen readers.
class ActivityChart extends StatefulWidget {
  const ActivityChart({
    super.key,
    required this.points,
    required this.unit,
    required this.format,
    required this.summary,
    this.kind = ChartKind.bars,
    this.height = 180,
  });

  final List<DayPoint> points;

  /// Unit shown on the axis, e.g. « pas », « h », « bpm ».
  final String unit;

  /// Value of the selected day, with its unit.
  final String Function(num value) format;
  final String summary;
  final ChartKind kind;
  final double height;

  @override
  State<ActivityChart> createState() => _ActivityChartState();
}

class _ActivityChartState extends State<ActivityChart> {
  int? _selected;

  @override
  void didUpdateWidget(ActivityChart old) {
    super.didUpdateWidget(old);
    if (old.points.length != widget.points.length) _selected = null;
  }

  void _select(Offset position, double width) {
    final n = widget.points.length;
    if (n == 0) return;
    final index =
        ((position.dx - _ChartPainter.axis) /
                ((width - _ChartPainter.axis) / n))
            .floor()
            .clamp(0, n - 1);
    if (index != _selected) setState(() => _selected = index);
  }

  String _detail(DayPoint p) {
    final day = longDay(p.day);
    return switch (p.state) {
      DayState.missing => '$day : aucune donnée',
      DayState.partial =>
        '$day : ${widget.format(p.value!)} (journée partielle)',
      DayState.complete =>
        p.low != null
            ? '$day : ${widget.format(p.value!)} '
                  '(min ${p.low}, max ${p.high})'
            : '$day : ${widget.format(p.value!)}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _selected;
    return Semantics(
      container: true,
      label: widget.summary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: SizedBox(
              height: 20,
              child: Text(
                selected == null
                    ? 'Touchez un jour pour voir sa valeur'
                    : _detail(widget.points[selected]),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: Space.xs),
          ExcludeSemantics(
            child: LayoutBuilder(
              builder: (context, box) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _select(d.localPosition, box.maxWidth),
                onHorizontalDragUpdate: (d) =>
                    _select(d.localPosition, box.maxWidth),
                child: CustomPaint(
                  size: Size(box.maxWidth, widget.height),
                  painter: _ChartPainter(
                    points: widget.points,
                    kind: widget.kind,
                    unit: widget.unit,
                    selected: selected,
                    color: scheme.primary,
                    muted: scheme.outline,
                    grid: scheme.outlineVariant,
                    text: theme.textTheme.labelSmall!.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.xs),
          ExcludeSemantics(
            child: _Legend(color: scheme.primary, muted: scheme.outline),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.muted});

  final Color color;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    Widget item(Widget mark, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 4),
        Text(label, style: style),
      ],
    );
    return Wrap(
      spacing: Space.m,
      children: [
        item(Container(width: 10, height: 10, color: color), 'complète'),
        item(
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.35),
              border: Border.all(color: color),
            ),
          ),
          'partielle',
        ),
        item(Text('×', style: style?.copyWith(color: muted)), 'sans donnée'),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.points,
    required this.kind,
    required this.unit,
    required this.selected,
    required this.color,
    required this.muted,
    required this.grid,
    required this.text,
  });

  static const axis = 40.0;
  static const bottom = 18.0;

  final List<DayPoint> points;
  final ChartKind kind;
  final String unit;
  final int? selected;
  final Color color;
  final Color muted;
  final Color grid;
  final TextStyle text;

  static double niceMax(num max) {
    if (max <= 0) return 1;
    final magnitude = math.pow(10, (math.log(max) / math.ln10).floor());
    for (final step in [1, 2, 2.5, 5, 10]) {
      final candidate = step * magnitude;
      if (candidate >= max) return candidate.toDouble();
    }
    return (10 * magnitude).toDouble();
  }

  void _label(Canvas canvas, String value, Offset at, {bool right = false}) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: text),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      right ? at - Offset(painter.width, painter.height / 2) : at,
    );
  }

  String _axisValue(double v) => v >= 10000
      ? '${(v / 1000).toStringAsFixed(0)} k'
      : v == v.roundToDouble()
      ? v.toStringAsFixed(0)
      : v.toStringAsFixed(1);

  @override
  void paint(Canvas canvas, Size size) {
    final n = points.length;
    if (n == 0) return;
    final chart = Rect.fromLTRB(axis, 4, size.width, size.height - bottom);
    final values = [
      for (final p in points) ...[?p.low, ?p.high, ?p.value],
    ];
    final low = kind == ChartKind.line && values.isNotEmpty
        ? math.max(0, (values.reduce(math.min) - 10) ~/ 10 * 10).toDouble()
        : 0.0;
    final top = niceMax(values.isEmpty ? 1 : values.reduce(math.max));
    double y(num v) =>
        chart.bottom - (v - low) / math.max(1, top - low) * chart.height;
    final slot = chart.width / n;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final v = low + (top - low) * i / 2;
      canvas.drawLine(
        Offset(chart.left, y(v)),
        Offset(chart.right, y(v)),
        gridPaint,
      );
      _label(canvas, _axisValue(v), Offset(axis - 4, y(v)), right: true);
    }
    _label(canvas, unit, Offset(0, chart.top - 2));

    if (selected != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          chart.left + slot * selected!,
          chart.top,
          slot,
          chart.height,
        ),
        Paint()..color = color.withValues(alpha: 0.12),
      );
    }

    final fill = Paint()..color = color;
    final light = Paint()..color = color.withValues(alpha: 0.35);
    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final missing = Paint()
      ..color = muted
      ..strokeWidth = 1.5;
    Offset? previous;
    for (var i = 0; i < n; i++) {
      final p = points[i];
      final cx = chart.left + slot * (i + 0.5);
      if (p.value == null) {
        // Cross on the baseline: no data, not zero.
        final r = math.min(4.0, slot / 3);
        final by = chart.bottom - 6;
        canvas.drawLine(
          Offset(cx - r, by - r),
          Offset(cx + r, by + r),
          missing,
        );
        canvas.drawLine(
          Offset(cx - r, by + r),
          Offset(cx + r, by - r),
          missing,
        );
        previous = null;
        continue;
      }
      final partial = p.state == DayState.partial;
      if (kind == ChartKind.bars) {
        final w = math.max(2.0, slot * 0.7);
        final rect = Rect.fromLTRB(
          cx - w / 2,
          y(p.value!),
          cx + w / 2,
          chart.bottom,
        );
        canvas.drawRect(rect, partial ? light : fill);
        if (partial) canvas.drawRect(rect, outline);
      } else {
        if (p.low != null && p.high != null) {
          canvas.drawLine(
            Offset(cx, y(p.low!)),
            Offset(cx, y(p.high!)),
            Paint()
              ..color = color.withValues(alpha: 0.35)
              ..strokeWidth = math.max(2, slot * 0.3),
          );
        }
        final point = Offset(cx, y(p.value!));
        if (previous != null) {
          canvas.drawLine(
            previous,
            point,
            Paint()
              ..color = color
              ..strokeWidth = 2,
          );
        }
        canvas.drawCircle(point, 3, partial ? light : fill);
        if (partial) canvas.drawCircle(point, 3, outline);
        previous = point;
      }
    }

    // First, middle and last dates.
    for (final i in {0, n ~/ 2, n - 1}) {
      final label = shortDay(points[i].day);
      final painter = TextPainter(
        text: TextSpan(text: label, style: text),
        textDirection: TextDirection.ltr,
      )..layout();
      final cx = chart.left + slot * (i + 0.5) - painter.width / 2;
      painter.paint(
        canvas,
        Offset(
          cx.clamp(chart.left, size.width - painter.width),
          chart.bottom + 3,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.points != points || old.selected != selected || old.color != color;
}
