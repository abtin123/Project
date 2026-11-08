import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lane arrows for the next maneuver, parsed from OSM `turn:lanes`
/// ("left|through|through;right"). Lanes that serve the maneuver are bright.
class LaneGuidanceStrip extends StatelessWidget {
  const LaneGuidanceStrip({
    super.key,
    required this.turnLanes,
    required this.modifier,
    this.activeColor = const Color(0xFF3DFFB5),
    this.maxWidth = 360,
  });

  final String turnLanes;
  final String? modifier;
  final Color activeColor;
  final double maxWidth;

  static List<List<String>> parse(String raw) {
    if (raw.trim().isEmpty) return const [];
    return [
      for (final lane in raw.toLowerCase().split('|'))
        [
          for (final t in lane.split(';'))
            t.trim().isEmpty || t.trim() == 'none' ? 'through' : t.trim(),
        ],
    ];
  }

  static Set<String> _serves(String? modifier) {
    switch ((modifier ?? '').toLowerCase()) {
      case 'left':
        return {'left', 'sharp_left', 'slight_left'};
      case 'sharp left':
        return {'sharp_left', 'left'};
      case 'slight left':
        return {'slight_left', 'left', 'through'};
      case 'right':
        return {'right', 'sharp_right', 'slight_right'};
      case 'sharp right':
        return {'sharp_right', 'right'};
      case 'slight right':
        return {'slight_right', 'right', 'through'};
      case 'uturn':
        return {'reverse', 'left', 'sharp_left'};
      default:
        return {'through'};
    }
  }

  /// True when at least one lane serves the maneuver and at least one doesn't
  /// (otherwise the strip carries no information).
  static bool isUseful(String raw, String? modifier) {
    final lanes = parse(raw);
    if (lanes.length < 2 || lanes.length > 8) return false;
    final serves = _serves(modifier);
    final n = lanes.where((l) => l.any(serves.contains)).length;
    return n > 0 && n < lanes.length;
  }

  @override
  Widget build(BuildContext context) {
    final lanes = parse(turnLanes);
    if (lanes.isEmpty) return const SizedBox.shrink();
    final serves = _serves(modifier);
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xE6101429),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final lane in lanes)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: CustomPaint(
                size: const Size(30, 42),
                painter: _LanePainter(
                  lane,
                  lane.any(serves.contains),
                  serves,
                  activeColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter(this.tokens, this.active, this.serves, this.color);

  final List<String> tokens;
  final bool active;
  final Set<String> serves;
  final Color color;

  static double? _angle(String t) => switch (t) {
        'through' => 0,
        'slight_left' => -45,
        'left' => -90,
        'sharp_left' => -135,
        'slight_right' => 45,
        'right' => 90,
        'sharp_right' => 135,
        'reverse' => 180,
        _ => null,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..color = active ? color.withOpacity(.18) : Colors.white.withOpacity(.06);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      bg,
    );
    final base = Offset(size.width / 2, size.height - 6);
    final fork = Offset(size.width / 2, size.height * 0.58);
    final len = size.height * 0.42;
    for (final t in tokens) {
      final a = _angle(t);
      if (a == null) continue;
      final on = serves.contains(t);
      final paint = Paint()
        ..color = on ? color : Colors.white.withOpacity(active ? .55 : .35)
        ..strokeWidth = on ? 3.4 : 2.6
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final rad = a * math.pi / 180;
      final dir = Offset(math.sin(rad), -math.cos(rad));
      final tip = fork + dir * len * (a.abs() == 0 ? 1.0 : 0.9);
      final path = Path()..moveTo(base.dx, base.dy)..lineTo(fork.dx, fork.dy);
      if (a != 0) path.lineTo(tip.dx, tip.dy);
      if (a == 0) path.lineTo(fork.dx, fork.dy - len);
      canvas.drawPath(path, paint);
      final end = a == 0 ? Offset(fork.dx, fork.dy - len) : tip;
      final heading = a == 0 ? 0.0 : rad;
      final head = Path();
      for (final side in [-1, 1]) {
        final ang = heading + math.pi + side * 0.6;
        head
          ..moveTo(end.dx, end.dy)
          ..lineTo(end.dx + math.sin(ang) * 8, end.dy - math.cos(ang) * 8);
      }
      canvas.drawPath(head, paint);
    }
  }

  @override
  bool shouldRepaint(_LanePainter old) =>
      old.tokens != tokens || old.active != active || old.color != color;
}
