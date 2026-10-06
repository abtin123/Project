import 'package:flutter/material.dart';

/// آیکونِ ضخیم برای HUD.
///
/// آیکون‌های Material خیلی نازک‌اند و روی شیشهٔ جلو کم‌دیده می‌شوند. این ویجت
/// همان گلیفِ آیکون را یک بار پُر و یک بار با خطِ دورِ هم‌رنگ می‌کشد؛ نتیجه
/// همان شکل (فلش چپ/راست/دوربرگردان/میدان/...) با ضخامتِ تقریباً دوبرابر است.
class HudBoldIcon extends StatelessWidget {
  const HudBoldIcon(
    this.icon, {
    super.key,
    required this.color,
    required this.size,
    this.boldness = 0.09,
  });

  final IconData icon;
  final Color color;
  final double size;

  /// ضخامتِ خطِ دور، به‌صورت نسبت از [size].
  final double boldness;

  @override
  Widget build(BuildContext context) {
    final glyph = String.fromCharCode(icon.codePoint);
    final base = TextStyle(
      inherit: false,
      fontFamily: icon.fontFamily,
      package: icon.fontPackage,
      fontSize: size,
      height: 1.0,
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Text(
            glyph,
            softWrap: false,
            style: base.copyWith(color: color),
          ),
          Text(
            glyph,
            softWrap: false,
            style: base.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = size * boldness
                ..strokeJoin = StrokeJoin.round
                ..strokeCap = StrokeCap.round
                ..color = color,
            ),
          ),
        ],
      ),
    );
  }
}
