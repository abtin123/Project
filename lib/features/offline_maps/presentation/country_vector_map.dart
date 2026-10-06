import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../../../core/theme/app_colors.dart';
import '../data/map_catalog.dart';
import 'iran_province_map.dart';
import 'iran_province_paths.dart';
import 'zoomable_map_view.dart';

/// Country-specific vector preview used only by the map-download screen.
///
/// Each country has its own SVG generated from the supplied country vector
/// source. This widget deliberately does not use the home-screen world map.
class CountryVectorMap extends StatelessWidget {
  // Parsed outlines are cached per country: the Iran painter caches geometry
  // by list identity, so the same list instance must be reused on rebuilds.
  static final Map<String, List<IranProvincePathData>> _shapeCache =
      <String, List<IranProvincePathData>>{};

  static Future<List<IranProvincePathData>> _loadShape(String code) async {
    final cached = _shapeCache[code];
    if (cached != null) return cached;
    final svg = await rootBundle.loadString('assets/maps/countries/$code.svg');
    final ds = RegExp(r'\sd="([^"]+)"')
        .allMatches(svg)
        .map((m) => m.group(1)!)
        .toList();
    if (ds.isEmpty) throw StateError('No path data in $code.svg');
    final shape = <IranProvincePathData>[
      IranProvincePathData(id: code, nameFa: '', d: ds.join(' ')),
    ];
    _shapeCache[code] = shape;
    return shape;
  }

  const CountryVectorMap({
    super.key,
    required this.countryCode,
    required this.regions,
    required this.installedIds,
    required this.updateIds,
    this.height = 350,
    this.showUpdates = true,
  });

  final String countryCode;
  final List<MapRegion> regions;
  final Set<String> installedIds;
  final Set<String> updateIds;
  final double height;
  final bool showUpdates;

  @override
  Widget build(BuildContext context) {
    final code = countryCode.trim().toLowerCase();
    final accent = AppColors.primaryAccent(context);

    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: FutureBuilder<List<IranProvincePathData>>(
          future: _loadShape(code),
          initialData: _shapeCache[code],
          builder: (context, snapshot) {
            if (!snapshot.hasData &&
                snapshot.connectionState != ConnectionState.done) {
              return Center(
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: accent),
              );
            }
            if (snapshot.hasError ||
                !snapshot.hasData ||
                snapshot.data!.isEmpty) {
              return _MissingCountryMap(code: countryCode);
            }

            final allInstalled = regions.isNotEmpty &&
                regions.every((r) => installedIds.contains(r.id));
            final anyInstalled =
                regions.any((r) => installedIds.contains(r.id));
            final anyUpdate = showUpdates &&
                regions.any((r) => updateIds.contains(r.id));
            // Same colours as the Iran map: white = available, green =
            // installed, blue = update. A country is one shape, so green only
            // applies once every package of the country is installed.
            final shape = snapshot.data!;
            final states = <String, IranProvinceVisualState>{
              shape.first.id: IranProvinceVisualState(
                installed: allInstalled,
                updatable: anyUpdate,
                downloading: false,
                selected: false,
                accent: accent,
              ),
            };
            final labels = <String, String>{shape.first.id: ''};

            return Stack(
              fit: StackFit.expand,
              children: [
                ZoomableMapView(
                  builder: (context, size, zoom) => Padding(
                    padding: const EdgeInsets.all(14),
                    child: CustomPaint(
                      size: size,
                      painter: IranProvinceMapPainter(
                        states: states,
                        labels: labels,
                        borderColor: const Color(0xFFC7DAFF),
                        zoom: zoom,
                        data: shape,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  top: 10,
                  child: IgnorePointer(
                    child: _StatusChip(
                      installed: anyInstalled,
                      update: anyUpdate,
                      accent: accent,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.installed,
    required this.update,
    required this.accent,
  });

  final bool installed;
  final bool update;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final Color color = update
        ? const Color(0xFF2E9BFF)
        : installed
            ? const Color(0xFF3DDC84)
            : accent;
    final String text = update
        ? 'Update'
        : installed
            ? 'Downloaded'
            : 'Available';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF020D1D).withOpacity(.82),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(.65)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissingCountryMap extends StatelessWidget {
  const _MissingCountryMap({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'SVG map unavailable: $code',
        style: TextStyle(
          color: AppColors.textSecondary(context),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
