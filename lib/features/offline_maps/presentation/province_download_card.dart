import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../data/map_catalog.dart';
import 'country_province_map.dart'
    show kProvinceDataByCountry, provinceKey;
import 'iran_province_map.dart';
import 'iran_province_paths.dart';
import 'map_download_providers.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

const Color kDlGreen = Color(0xFF18B88A);
const Color kDlBlue = Color(0xFF2E9BFF);
const Color kDlViolet = Color(0xFF6B6BFF);
const Color kDlBorder = Color(0xFF2F5BFF);

String fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

String fmtSizeMb(double mb) {
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  if (mb >= 1) return 'MB ${mb.toStringAsFixed(0)}';
  if (mb > 0) return 'KB ${(mb * 1024).toStringAsFixed(0)}';
  return '—';
}

class CircularDownloadButton extends StatelessWidget {
  const CircularDownloadButton({
    super.key,
    required this.progress,
    required this.icon,
    required this.onTap,
    this.size = 52,
    this.color = kDlGreen,
  });

  final double progress;
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withOpacity(.12),
          boxShadow: [
            BoxShadow(color: color.withOpacity(.35), blurRadius: 14),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size.square(size),
              painter: _RingPainter(progress: progress, color: color),
            ),
            AppIcon(icon, color: Colors.white, size: size * .46),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.5;
    final r = (math.min(size.width, size.height) - stroke) / 2;
    final c = size.center(Offset.zero);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withOpacity(.22),
    );
    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color;
}

class ProvinceDownloadCard extends ConsumerStatefulWidget {
  const ProvinceDownloadCard({
    super.key,
    required this.region,
    required this.installed,
    required this.updatable,
    required this.isEnglish,
    this.downloadedTab = true,
  });

  final MapRegion region;
  final bool installed;
  final bool updatable;
  final bool isEnglish;
  final bool downloadedTab;

  @override
  ConsumerState<ProvinceDownloadCard> createState() =>
      _ProvinceDownloadCardState();
}

class _ProvinceDownloadCardState extends ConsumerState<ProvinceDownloadCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final region = widget.region;
    final installed = widget.installed;
    final updatable = widget.downloadedTab && widget.updatable;
    final dl = ref.watch(regionDownloadControllerProvider(region));
    final notifier =
        ref.read(regionDownloadControllerProvider(region).notifier);

    final staged = installed && !updatable
        ? 0
        : (ref.watch(regionStagedBytesProvider(region)).valueOrNull ?? 0);
    final total =
        region.totalSizeBytes > 0 ? region.totalSizeBytes : (dl.total ?? 0);
    final received = math.max(dl.received, staged);
    final progress = total > 0
        ? (received / total).clamp(0.0, 1.0).toDouble()
        : (dl.fraction ?? 0);
    final partial =
        !dl.downloading && received > 0 && (!installed || updatable);
    final done = installed && !dl.downloading && !partial;

    final String status;
    final Color statusColor;
    if (dl.downloading) {
      status = dl.phase == RegionDownloadPhase.building
          ? AppStrings.get(context, ref, 'map_building')
          : dl.phase == RegionDownloadPhase.saving
              ? AppStrings.get(context, ref, 'map_saving')
              : AppStrings.literal('در حال دانلود');
      statusColor = kDlGreen;
    } else if (updatable) {
      status = AppStrings.get(context, ref, 'map_update_available');
      statusColor = kDlBlue;
    } else if (installed) {
      status = AppStrings.get(context, ref, 'map_downloaded');
      statusColor = kDlGreen;
    } else if (partial) {
      status = AppStrings.literal('متوقف‌شده');
      statusColor = kDlViolet;
    } else {
      status = AppStrings.literal('آماده دانلود');
      statusColor = Colors.white70;
    }

    final IconData icon;
    final VoidCallback? onTap;
    if (dl.downloading) {
      icon = Icons.pause_rounded;
      onTap = notifier.pause;
    } else if (done) {
      icon = Icons.check_rounded;
      onTap = null;
    } else if (partial) {
      icon = Icons.play_arrow_rounded;
      onTap = () => notifier.start();
    } else {
      icon = Icons.arrow_downward_rounded;
      onTap = () => notifier.start();
    }
    final ringProgress = done ? 1.0 : progress;

    final sizeText = (dl.downloading || partial) && total > 0
        ? '${fmtBytes(received)} / ${fmtBytes(total)}'
        : fmtSizeMb(region.totalSizeMb);

    final canExpand = installed && widget.downloadedTab;
    final showActions = canExpand && _expanded && !dl.downloading;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF061A3A), Color(0xFF03101F)],
        ),
        border: Border.all(color: kDlBorder.withOpacity(.85), width: 1.2),
        boxShadow: [
          BoxShadow(color: kDlBorder.withOpacity(.16), blurRadius: 16),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              children: [
                CircularDownloadButton(
                  progress: ringProgress,
                  icon: icon,
                  onTap: onTap,
                  color: dl.downloading || done ? kDlGreen : kDlViolet,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          region.displayRegionName(widget.isEnglish),
                          maxLines: 1,
                          style: TextStyle(
                            color: AppColors.textPrimary(context),
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          sizeText,
                          maxLines: 1,
                          style: TextStyle(
                            color: AppColors.textPrimary(context)
                                .withOpacity(.92),
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (!dl.downloading) ...[
                  _StatusCapsule(
                    text: status,
                    color: statusColor,
                    spinning: false,
                  ),
                  const SizedBox(width: 8),
                ],
                _RegionThumb(region: region, color: statusColor),
                SizedBox(
                  width: 28,
                  child: canExpand
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _expanded = !_expanded),
                          child: AppIcon(
                            _expanded
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
          if (showActions) ...[
            const SizedBox(height: 12),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Row(
                children: [
                  Expanded(
                    child: _PillButton(
                      icon: Icons.system_update_alt_rounded,
                      label: AppStrings.get(context, ref, 'map_update_action'),
                      color: kDlBlue,
                      enabled: updatable,
                      onTap: () => notifier.start(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PillButton(
                      icon: Icons.delete_outline_rounded,
                      label: AppStrings.get(context, ref, 'map_delete_action'),
                      color: const Color(0xFFE5544B),
                      enabled: true,
                      onTap: notifier.delete,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusCapsule extends StatelessWidget {
  const _StatusCapsule(
      {required this.text, required this.color, required this.spinning});
  final String text;
  final Color color;
  final bool spinning;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withOpacity(.14),
        border: Border.all(color: color.withOpacity(.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          spinning
              ? SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.8, color: color),
                )
              : Container(
                  width: 7,
                  height: 7,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
          const SizedBox(width: 5),
          Text(
            text,
            maxLines: 1,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _RegionThumb extends StatelessWidget {
  const _RegionThumb({required this.region, required this.color});
  final MapRegion region;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    final key = provinceKey(region.id);
    IranProvincePathData? data;
    for (final d in kProvinceDataByCountry[region.effectiveCountryCode] ??
        const <IranProvincePathData>[]) {
      if (d.id == key) {
        data = d;
        break;
      }
    }
    if (data != null) {
      child = CustomPaint(
        painter: _ThumbPainter(
          path: IranProvinceMapPainter.parseSvgPath(data.d),
          color: color == Colors.white70 ? const Color(0xFFF5F7FB) : color,
        ),
      );
    } else {
      final code = region.effectiveCountryCode.toLowerCase();
      child = Padding(
        padding: const EdgeInsets.all(5),
        child: SvgPicture.asset(
          'assets/maps/countries/$code.svg',
          fit: BoxFit.contain,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          errorBuilder: (_, __, ___) =>
              AppIcon(Icons.map_rounded, color: color, size: 22),
        ),
      );
    }
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withOpacity(.10),
        border: Border.all(color: color.withOpacity(.75), width: 1.2),
      ),
      child: child,
    );
  }
}

class _ThumbPainter extends CustomPainter {
  const _ThumbPainter({required this.path, required this.color});
  final Path path;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final b = path.getBounds();
    const pad = 6.0;
    final s = math.min((size.width - pad * 2) / b.width,
        (size.height - pad * 2) / b.height);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(s);
    canvas.translate(-b.center.dx, -b.center.dy);
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ThumbPainter old) =>
      old.path != path || old.color != color;
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = enabled ? color : Colors.white24;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: c.withOpacity(enabled ? .16 : .06),
          border: Border.all(color: c.withOpacity(enabled ? .8 : .4), width: 1.2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon(icon, color: enabled ? c : Colors.white38, size: 19),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: enabled ? Colors.white : Colors.white38,
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
