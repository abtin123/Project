import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'abm_road_hazards.dart';
import 'abm_saved_places.dart';
import '../shared/providers/map_style_providers.dart' show roadZoomBandOf;


/// The one MapLibre style used by every map state (online/offline, day/night).
///
/// `assets/styles/abtin_unified_style.json` is the only place layers are
/// defined. It carries both data families -- OpenMapTiles (online) and the
/// ABM SQLite/GeoJSON sources (offline) -- and states its own conditions:
///  * `metadata["abm:source-modes"]` says which mode each source serves;
///  * a layer's `metadata["abm:offline"]` re-points that layer at an offline
///    source (buildings share one definition for both modes);
///  * `metadata["abm:palette"]` holds the day/night default colours that
///    `{{token}}` placeholders in offline-only layers resolve to.
///
/// MapLibre cannot switch a layer's data source with an expression, so the
/// condition is evaluated when the style is written: layers/sources that
/// don't serve the current mode are dropped from the output. Exactly one
/// generated style file exists at a time (content-hash named, see
/// [_writeStyle]), so any change of mode, theme or palette yields a new path.
class AbmStyleAssets {
  AbmStyleAssets._();

  static final AbmStyleAssets instance = AbmStyleAssets._();

  static const String _assetRevision = 'abtin-unified-maplibre-style-v6';
  static const String _bundledStyle = 'assets/styles/abtin_unified_style.json';
  static const List<String> _fontstacks = ['Vazirmatn', 'VazirmatnBold'];
  static const List<String> _ranges = [
    '0-255', '256-511', '1536-1791', '1792-2047', '8192-8447',
    '64256-64511', '64512-64767', '65024-65279', '65280-65535',
  ];

  Directory? _root;

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final root = Directory('${base.path}/abm_style/$_assetRevision');
    await root.create(recursive: true);

    for (final stack in _fontstacks) {
      final dir = Directory('${root.path}/glyphs/$stack');
      await dir.create(recursive: true);
      for (final range in _ranges) {
        await _copyAsset(
          'assets/glyphs/$stack/$range.pbf',
          File('${dir.path}/$range.pbf'),
        );
      }
    }

    final spriteDir = Directory('${root.path}/sprites');
    await spriteDir.create(recursive: true);
    for (final name in const [
      'abtin.json', 'abtin.png', 'abtin@2x.json', 'abtin@2x.png',
    ]) {
      await _copyAsset('assets/sprites/$name', File('${spriteDir.path}/$name'));
    }
    _root = root;
    return root;
  }

  Future<void> _copyAsset(String assetPath, File target) async {
    final data = await rootBundle.load(assetPath);
    await target.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }

  String _hex(String value) => value.startsWith('#') ? value : '#$value';

  Map<String, dynamic> _copyStyle(Map<String, dynamic> raw) =>
      jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;

  /// The bundled base style (built for a global OpenMapTiles basemap) shows
  /// every place/POI/road/water name as `"latin-transliteration Persian"`
  /// whenever the source tile has a `name:nonlatin` value -- a global
  /// bilingual convention that, for an Iran-focused app reading mostly
  /// Persian OSM data, means every label prints a second, often
  /// low-quality auto-transliterated Latin string in front of the real
  /// name. That's very likely what read as "names aren't displaying
  /// correctly": not a missing label, but every label showing extra noise.
  ///
  /// Offline already only ever shows one name (`coalesce(name, name_fa,
  /// name_en)`). Rewriting the same `case`/`concat` pattern here, before
  /// online/offline branch at all, means text logic no longer has two
  /// separate implementations to keep in sync -- online and offline read
  /// the exact same simplified expression.
  void _localizeTextFields(Map<String, dynamic> style) {
    bool isBilingualConcat(dynamic textField) {
      if (textField is! List || textField.length < 3 || textField[0] != 'case') {
        return false;
      }
      final thenBranch = textField[2];
      return thenBranch is List && thenBranch.isNotEmpty && thenBranch[0] == 'concat';
    }

    final layers = <Map<String, dynamic>>[];
    for (final raw in (style['layers'] as List? ?? const [])) {
      final layer = Map<String, dynamic>.from(raw as Map);
      final layout = Map<String, dynamic>.from(
        (layer['layout'] as Map? ?? const {}).map((k, v) => MapEntry('$k', v)),
      );
      if (isBilingualConcat(layout['text-field'])) {
        layout['text-field'] = <dynamic>[
          'coalesce',
          <dynamic>['get', 'name'],
          <dynamic>['get', 'name:nonlatin'],
          <dynamic>['get', 'name_en'],
          <dynamic>['get', 'name:latin'],
        ];
        layer['layout'] = layout;
      }
      layers.add(layer);
    }
    style['layers'] = layers;
  }

  void _applyPalette(
    Map<String, dynamic> style, {
    required Map<String, String> colors,
    required bool dark,
    String? roadDirectionArrowColorHex,
    double? roadDirectionArrowSizePercent,
  }) {
    final layers = <Map<String, dynamic>>[];
    for (final raw in (style['layers'] as List? ?? const [])) {
      final layer = Map<String, dynamic>.from(raw as Map);
      // Offline-only layers take their colours from `{{token}}` placeholders
      // (resolved from the style's own palette), not from the heuristics below.
      if (_asMap(layer['metadata'])['abm:tokens'] == true) {
        layers.add(layer);
        continue;
      }
      final paint = Map<String, dynamic>.from(
        (layer['paint'] as Map? ?? const {}).map(
          (k, v) => MapEntry('$k', v),
        ),
      );
      final layout = Map<String, dynamic>.from(
        (layer['layout'] as Map? ?? const {}).map(
          (k, v) => MapEntry('$k', v),
        ),
      );
      final type = '${layer['type'] ?? ''}';
      final id = '${layer['id'] ?? ''}'.toLowerCase();
      final sourceLayer = '${layer['source-layer'] ?? ''}'.toLowerCase();
      final source = '${layer['source'] ?? ''}';
      String pick(String key, String _) { final value = colors[key]; if (value == null || value.isEmpty) throw StateError('Missing map palette color: $key'); return _hex(value); }

      if (type == 'background') {
        paint['background-color'] = pick('background', '');
      }

      if (id == 'road_one_way_arrow' ||
          id == 'road_one_way_arrow_opposite' ||
          id.startsWith('abm-road-oneway-arrow')) {
        paint['icon-color'] = _hex(roadDirectionArrowColorHex ?? colors['label']!);
        layout['icon-size'] =
            ((roadDirectionArrowSizePercent ?? 70.0) / 100.0)
                .clamp(0.3, 2.0)
                .toDouble();
        layout['icon-allow-overlap'] = true;
        layer['layout'] = layout;
      }

      if (type == 'fill' || type == 'fill-extrusion') {
        if (sourceLayer == 'water' || sourceLayer == 'waterway') {
          paint[type == 'fill-extrusion' ? 'fill-extrusion-color' : 'fill-color'] =
              pick('water', '');
        } else if (sourceLayer == 'park' || sourceLayer == 'landcover') {
          paint[type == 'fill-extrusion' ? 'fill-extrusion-color' : 'fill-color'] =
              pick('green', '');
        } else if (sourceLayer == 'landuse') {
          paint[type == 'fill-extrusion' ? 'fill-extrusion-color' : 'fill-color'] =
              pick('urban', '');
        } else if (sourceLayer == 'building') {
          paint[type == 'fill-extrusion' ? 'fill-extrusion-color' : 'fill-color'] =
              pick('building', '');
          if (paint.containsKey('fill-outline-color')) {
            paint['fill-outline-color'] =
                pick('building', '');
          }
        }
      }

      if (type == 'line' && sourceLayer == 'transportation') {
        if (id.contains('casing') || id.contains('hatching')) {
          paint['line-color'] = pick('roadOutline', '');
        } else if (id.contains('motorway')) {
          paint['line-color'] = pick('roadMotorway', '');
        } else if (id.contains('trunk')) {
          paint['line-color'] = pick('roadTrunk', '');
        } else if (id.contains('primary')) {
          paint['line-color'] = pick('roadPrimary', '');
        } else if (id.contains('secondary') || id.contains('tertiary')) {
          paint['line-color'] = pick('roadSecondary', '');
        } else {
          paint['line-color'] = pick('roadLocal', '');
        }
      }

      if (type == 'line' && sourceLayer == 'boundary') {
        paint['line-color'] = pick('roadOutline', '');
      }

      if (type == 'symbol') {
        // Offline's hand-authored `poi-points`/`poi-labels` (source
        // `abm-poi`) carry no `source-layer`, so they must be recognized by
        // source id too -- otherwise they fall into the `label` bucket
        // instead of `poi` and never pick up the user's POI color.
        final isPoi = sourceLayer == 'poi' || source == 'abm-poi';
        if (paint.containsKey('text-color')) {
          paint['text-color'] = pick(isPoi ? 'poi' : 'label', '');
        }
        if (paint.containsKey('text-halo-color')) {
          paint['text-halo-color'] = pick('halo', '');
        }
      }

      layer['paint'] = paint;
      layers.add(layer);
    }
    style['layers'] = layers;
  }

  void _setLocalFontsAndAssets(
    Map<String, dynamic> style,
    Directory root,
  ) {
    style['glyphs'] =
        'file://${root.path}/glyphs/{fontstack}/{range}.pbf';
    style['sprite'] = 'file://${root.path}/sprites/abtin';
    for (final raw in (style['layers'] as List? ?? const [])) {
      final layer = Map<String, dynamic>.from(raw as Map);
      final layout = Map<String, dynamic>.from(
        (layer['layout'] as Map? ?? const {}).map(
          (k, v) => MapEntry('$k', v),
        ),
      );
      final fonts = layout['text-font'];
      if (fonts is List) {
        layout['text-font'] = fonts.map((font) {
          final value = '$font'.toLowerCase();
          return value.contains('bold') ? 'VazirmatnBold' : 'Vazirmatn';
        }).toList();
        layer['layout'] = layout;
      }
      final index = (style['layers'] as List).indexOf(raw);
      (style['layers'] as List)[index] = layer;
    }
  }

  Map<String, dynamic> _asMap(dynamic value) => value is Map
      ? Map<String, dynamic>.from(value.map((k, v) => MapEntry('$k', v)))
      : <String, dynamic>{};

  /// Keeps only what the current mode can draw. A layer stays when its
  /// source serves this mode (or both), it has no source (background), or --
  /// offline -- it declares an `abm:offline` override.
  void _selectMode(Map<String, dynamic> style, {required bool offline}) {
    final modes = _asMap(_asMap(style['metadata'])['abm:source-modes']);
    final want = offline ? 'offline' : 'online';
    final kept = <Map<String, dynamic>>[];
    for (final raw in (style['layers'] as List? ?? const [])) {
      final layer = Map<String, dynamic>.from(raw as Map);
      final source = layer['source'];
      final mode = source == null ? 'both' : '${modes['$source'] ?? 'both'}';
      final hasOfflineOverride =
          _asMap(_asMap(layer['metadata'])['abm:offline']).isNotEmpty;
      if (mode == 'both' || mode == want || (offline && hasOfflineOverride)) {
        kept.add(layer);
      }
    }
    style['layers'] = kept;
  }


  static List<dynamic> _numProp(String key) => <dynamic>[
        'case',
        <dynamic>['has', key],
        <dynamic>['to-number', <dynamic>['get', key], 0],
        0,
      ];

  /// ارتفاعِ ساختمان: render_height/height یا طبقات×۳٫۲ (OSM)، حداقل ۴ متر،
  /// و برای دیتایی که ارتفاع ندارد (mbtiles آفلاین) مقدار پیش‌فرض ۹ متر.
  static List<dynamic> get _buildingHeight => <dynamic>[
        'min',
        150, // سقف ارتفاع: داده‌های خراب/واحد اشتباه برج‌های غول‌پیکر نسازند
        <dynamic>['max',
        4,
        <dynamic>[
          'case',
          <dynamic>['>', _numProp('render_height'), 0],
          _numProp('render_height'),
          <dynamic>['>', _numProp('height'), 0],
          _numProp('height'),
          <dynamic>['>', _numProp('building:levels'), 0],
          <dynamic>['*', _numProp('building:levels'), 3.2],
          <dynamic>['>', _numProp('levels'), 0],
          <dynamic>['*', _numProp('levels'), 3.2],
          9,
        ],
        ],
      ];

  static String _shade(String hex, double f) {
    final v = int.parse(hex.replaceFirst('#', ''), radix: 16);
    int ch(int shift) {
      final c = (v >> shift) & 0xFF;
      final out = f >= 0 ? c + (255 - c) * f : c * (1 + f);
      return out.round().clamp(0, 255);
    }
    String h(int c) => c.toRadixString(16).padLeft(2, '0');
    return '#${h(ch(16))}${h(ch(8))}${h(ch(0))}';
  }

  /// ساختمان‌های ۳بعدی مثل حالت آنلاین: ارتفاع از دیتا، روشن‌ترشدنِ رنگ با
  /// ارتفاع، گرادیان عمودی و نور جهت‌دار برای تفکیکِ دیواره‌ها.
  void _apply3dBuildings(Map<String, dynamic> style, String colorHex) {
    final base = _hex(colorHex);
    final layers = <Map<String, dynamic>>[];
    for (final raw in (style['layers'] as List? ?? const [])) {
      final layer = Map<String, dynamic>.from(raw as Map);
      final sl = '${layer['source-layer'] ?? ''}';
      if (layer['type'] == 'fill-extrusion' &&
          (sl == 'building' || sl == 'buildings')) {
        final paint = Map<String, dynamic>.from(
          (layer['paint'] as Map? ?? const {}).map((k, v) => MapEntry('$k', v)),
        );
        paint['fill-extrusion-height'] = _buildingHeight;
        paint['fill-extrusion-base'] = <dynamic>[
          'min',
          <dynamic>[
            'case',
            <dynamic>['>', _numProp('render_min_height'), 0],
            _numProp('render_min_height'),
            _numProp('min_height'),
          ],
          <dynamic>['-', _buildingHeight, 1],
        ];
        paint['fill-extrusion-color'] = <dynamic>[
          'interpolate', <dynamic>['linear'], _buildingHeight,
          4, _shade(base, -0.12),
          30, base,
          100, _shade(base, 0.22),
        ];
        paint['fill-extrusion-vertical-gradient'] = true;
        paint['fill-extrusion-opacity'] = 1.0;
        layer['paint'] = paint;
        layer['minzoom'] = 13;
        // Outline polygons that are covered by building:part polygons must not
        // be extruded too, otherwise two overlapping prisms z-fight and give
        // stair-stepped / striped roofs and walls.
        final hide = <dynamic>[
          '!=', <dynamic>['to-string', <dynamic>['get', 'hide_3d']], 'true',
        ];
        final oldFilter = layer['filter'];
        layer['filter'] = oldFilter == null
            ? hide
            : <dynamic>['all', oldFilter, hide];
      }
      layers.add(layer);
    }
    // Draw the extrusions AFTER every road line/arrow (but before the route
    // and labels). Flat line layers do not depth-test against extrusions, so a
    // road layer placed after the buildings is painted over their roofs. With
    // the buildings later in the order, they occlude roads behind/under them
    // exactly like the online style does. Base layers (background, world map,
    // landuse, water) stay at the bottom and everything is stacked on them.
    final extrusions = <Map<String, dynamic>>[];
    final rest = <Map<String, dynamic>>[];
    for (final l in layers) {
      final sl = '${l['source-layer'] ?? ''}';
      if (l['type'] == 'fill-extrusion' &&
          (sl == 'building' || sl == 'buildings')) {
        extrusions.add(l);
      } else {
        rest.add(l);
      }
    }
    var insertAt = rest.indexWhere((l) => '${l['id']}'.startsWith('abm-route'));
    if (insertAt < 0) {
      insertAt = rest.lastIndexWhere((l) =>
              '${l['id']}'.startsWith('abm-road-') &&
              (l['type'] == 'line' || l['type'] == 'symbol') &&
              l['source'] == 'abm-tiles') +
          1;
    }
    if (extrusions.isNotEmpty && insertAt > 0) {
      rest.insertAll(insertAt, extrusions);
      style['layers'] = rest;
    } else {
      style['layers'] = layers;
    }
    style['light'] = <String, dynamic>{
      'anchor': 'map',
      'position': <dynamic>[1.15, 210, 60],
      'intensity': 0.3,
      'color': '#ffffff',
    };
  }

  /// Offline: re-point layers that declare `abm:offline` (e.g. buildings)
  /// at the offline source. Runs after [_applyPalette], which still keys
  /// its colour rules off the online source-layer name.
  /// Offline rendering uses province-specific MBTiles as the cartographic basemap.
  /// The GeoJSON sources are only for data that belongs to province-specific SQLite, such
  /// as POIs, places and local road-name metadata queried for the viewport.
  void _applyOfflineOverrides(
    Map<String, dynamic> style, {
    String? mbtilesPath,
  }) {
    if (mbtilesPath == null || mbtilesPath.isEmpty) return;
    final layers = <Map<String, dynamic>>[];
    for (final raw in (style['layers'] as List? ?? const [])) {
      final layer = Map<String, dynamic>.from(raw as Map);
      final offlineOverride = _asMap(_asMap(layer['metadata'])['abm:offline']);
      if (offlineOverride.isNotEmpty) {
        final overriddenSource = '${offlineOverride['source'] ?? ''}';
        if (overriddenSource == 'abm-tiles') {
          layer.addAll(offlineOverride);
        }
      }
      layers.add(layer);
    }
    style['layers'] = layers;
  }

  /// Apply the same user-selected palette to the online vector tiles too.
  /// The previous implementation only recoloured a subset of transportation
  /// layers; many OpenFreeMap layers kept their baked light colours, which is
  /// why Online could remain light while Offline was dark. This pass is
  /// deliberately source-layer/id based and covers the full basemap family.
  void _applyOnlinePalette(Map<String, dynamic> style, {
    required Map<String, String> palette,
    required bool dark,
  }) {
    String hex(String key) { final value = palette[key]; if (value == null || value.isEmpty) throw StateError('Missing map palette color: $key'); return _hex(value); }
    final layers = <Map<String, dynamic>>[];
    for (final raw in (style['layers'] as List? ?? const [])) {
      final layer = Map<String, dynamic>.from(raw as Map);
      final source = '${layer['source'] ?? ''}';
      if (source != 'openmaptiles') {
        layers.add(layer);
        continue;
      }
      final type = '${layer['type'] ?? ''}';
      final id = '${layer['id'] ?? ''}'.toLowerCase();
      final sourceLayer = '${layer['source-layer'] ?? ''}'.toLowerCase();
      final paint = Map<String, dynamic>.from(
        (layer['paint'] as Map? ?? const {}).map((k, v) => MapEntry('$k', v)),
      );

      if (type == 'background') {
        paint['background-color'] = hex('background');
      } else if (type == 'fill' || type == 'fill-extrusion') {
        final key = sourceLayer == 'water' || sourceLayer == 'waterway'
            ? 'water'
            : (sourceLayer == 'park' || sourceLayer == 'landcover'
                ? 'green'
                : (sourceLayer == 'building' ? 'building' : 'urban'));
        final colorKey = type == 'fill-extrusion' ? 'fill-extrusion-color' : 'fill-color';
        paint[colorKey] = hex(key);
        if (paint.containsKey('fill-outline-color')) {
          paint['fill-outline-color'] = hex(key == 'building' ? 'building' : 'roadOutline');
        }
      } else if (type == 'line' && sourceLayer == 'transportation') {
        final isCasing = id.contains('casing') || id.contains('hatching');
        final key = isCasing
            ? 'roadOutline'
            : id.contains('motorway')
                ? 'roadMotorway'
                : id.contains('trunk')
                    ? 'roadTrunk'
                    : id.contains('primary')
                        ? 'roadPrimary'
                        : (id.contains('secondary') || id.contains('tertiary'))
                            ? 'roadSecondary'
                            : 'roadLocal';
        paint['line-color'] = hex(key);
      } else if (type == 'line' && (sourceLayer == 'boundary' || sourceLayer == 'transportation_name')) {
        paint['line-color'] = hex('roadOutline');
      } else if (type == 'symbol') {
        if (paint.containsKey('text-color')) {
          paint['text-color'] = hex('label');
        }
        if (paint.containsKey('text-halo-color')) {
          paint['text-halo-color'] = hex('halo');
        }
        if (id.startsWith('poi_') && paint.containsKey('icon-color')) {
          paint['icon-color'] = hex('poi');
        }
      }
      layer['paint'] = paint;
      layers.add(layer);
    }
    style['layers'] = layers;
  }

  static dynamic _mulWidth(dynamic value, dynamic factor) {
    if (value is num && factor is num) return value * factor;
    return <dynamic>['*', factor, value];
  }

  /// ضریب را روی «خروجی‌های» عبارتِ پهنا اعمال می‌کند، نه روی کل عبارت:
  /// در MapLibre عبارتِ `zoom` فقط می‌تواند ورودیِ `interpolate`/`step` سطحِ بالا
  /// باشد، پس ضرب‌کردنِ کلِ عبارت در عدد استایل را نامعتبر می‌کند.
  static dynamic _scaleWidth(dynamic width, dynamic factor) {
    if (width is List && width.length >= 5 && width[0] == 'interpolate') {
      final out = List<dynamic>.from(width);
      for (var i = 4; i < out.length; i += 2) {
        out[i] = _scaleWidth(out[i], factor);
      }
      return out;
    }
    if (width is List && width.length >= 3 && width[0] == 'step') {
      final out = List<dynamic>.from(width);
      out[2] = _scaleWidth(out[2], factor);
      for (var i = 4; i < out.length; i += 2) {
        out[i] = _scaleWidth(out[i], factor);
      }
      return out;
    }
    return _mulWidth(width, factor);
  }

  /// پهنای جداگانهٔ هر گروه خیابان (آزادراه / بزرگراه / اصلی / فرعی / کوچه).
  /// آنلاین: لایه‌های `transportation` (خودِ راه + casing، به‌جز ریل)؛
  /// آفلاین: `abm-road-line` و `abm-road-casing`. گروه از property `class` خوانده
  /// می‌شود، پس لایه‌های ترکیبی مثل `road_trunk_primary` هم درست تفکیک می‌شوند.
  void _applyRoadWidths(
    Map<String, dynamic> style,
    Map<String, double> widths, [
    Map<int, Map<String, double>> zoomWidths = const {},
  ]) {
    if (zoomWidths.isNotEmpty) {
      _applyRoadWidthsPerZoom(style, widths, zoomWidths);
      return;
    }
    double k(String key) => (widths[key] ?? 1.0).clamp(0.2, 4.0).toDouble();
    final motorway = k('motorway');
    final trunk = k('trunk');
    final primary = k('primary');
    final secondary = k('secondary');
    final local = k('local');
    final all = <double>[motorway, trunk, primary, secondary, local];
    if (all.every((v) => (v - 1.0).abs() < 1e-6)) return;

    final dynamic factor = all.every((v) => (v - local).abs() < 1e-6)
        ? local
        : <dynamic>[
            'match',
            ['get', 'class'],
            ['motorway', 'motorway_link'],
            motorway,
            ['trunk', 'trunk_link'],
            trunk,
            ['primary', 'primary_link'],
            primary,
            ['secondary', 'secondary_link', 'tertiary', 'tertiary_link'],
            secondary,
            local,
          ];

    final layers = <Map<String, dynamic>>[];
    for (final raw in (style['layers'] as List? ?? const [])) {
      final layer = Map<String, dynamic>.from(raw as Map);
      final id = '${layer['id'] ?? ''}'.toLowerCase();
      final source = '${layer['source'] ?? ''}';
      final sourceLayer = '${layer['source-layer'] ?? ''}'.toLowerCase();
      final isRoadLine = '${layer['type']}' == 'line' &&
          ((source == 'openmaptiles' &&
                  sourceLayer == 'transportation' &&
                  !id.contains('rail')) ||
              (source == 'abm-tiles' && sourceLayer == 'roads'));
      if (isRoadLine) {
        final paint = Map<String, dynamic>.from(
          (layer['paint'] as Map? ?? const {}).map((k, v) => MapEntry('$k', v)),
        );
        if (paint['line-width'] != null) {
          paint['line-width'] = _scaleWidth(paint['line-width'], factor);
          layer['paint'] = paint;
        }
      }
      layers.add(layer);
    }
    style['layers'] = layers;
  }

  /// Evaluates a (zoom-only) `interpolate` width expression at [zoom].
  /// Returns null when the expression is not a plain numeric zoom curve.
  static double? _evalWidthAt(dynamic w, double zoom) {
    if (w is num) return w.toDouble();
    if (w is! List || w.length < 5 || w[0] != 'interpolate') return null;
    final type = w[1];
    if (type is! List || type.isEmpty) return null;
    final input = w[2];
    if (input is! List || input.length != 1 || input[0] != 'zoom') return null;
    final zs = <double>[];
    final vs = <double>[];
    for (var i = 3; i + 1 < w.length; i += 2) {
      final z = w[i], v = w[i + 1];
      if (z is! num || v is! num) return null;
      zs.add(z.toDouble());
      vs.add(v.toDouble());
    }
    if (zs.isEmpty) return null;
    if (zoom <= zs.first) return vs.first;
    if (zoom >= zs.last) return vs.last;
    for (var i = 0; i + 1 < zs.length; i++) {
      if (zoom <= zs[i + 1]) {
        final span = zs[i + 1] - zs[i];
        final d = zoom - zs[i];
        double t;
        if (type[0] == 'exponential' && type.length > 1 && type[1] is num) {
          final b = (type[1] as num).toDouble();
          t = (b - 1.0).abs() < 1e-6 ? d / span : (math.pow(b, d) - 1) / (math.pow(b, span) - 1);
        } else {
          t = d / span;
        }
        return vs[i] + (vs[i + 1] - vs[i]) * t;
      }
    }
    return vs.last;
  }

  /// Zoom stops (sorted, unique) of an `interpolate` width expression.
  static List<double> _widthStopZooms(dynamic w) {
    if (w is! List || w.length < 5 || w[0] != 'interpolate') return const [];
    return <double>[
      for (var i = 3; i + 1 < w.length; i += 2)
        if (w[i] is num) (w[i] as num).toDouble(),
    ];
  }

  /// Per-zoom road thickness. For every road line layer the width curve is
  /// re-sampled at each integer zoom (plus the layer's own stops) and every
  /// sample is multiplied by that zoom's per-class factor, so each zoom level
  /// can have its own thickness while MapLibre interpolates between them.
  void _applyRoadWidthsPerZoom(
    Map<String, dynamic> style,
    Map<String, double> widths,
    Map<int, Map<String, double>> zoomWidths,
  ) {
    const classes = ['motorway', 'trunk', 'primary', 'secondary', 'local'];
    double clampK(double v) => v.clamp(0.2, 4.0).toDouble();
    double factorFor(String cls, int zoom) {
      final z = zoomWidths[zoom];
      return clampK(z?[cls] ?? widths[cls] ?? 1.0);
    }

    // Factor at integer zoom (outside the configurable range -> nearest
    // configured edge so the curve stays stable).
    dynamic factorExprAt(int zoom) {
      // همهٔ زوم‌های یک باند همان ضریب اولین زوم باند را دارند.
      final z = roadZoomBandOf(zoom).$1;
      final v = <String, double>{for (final c in classes) c: factorFor(c, z)};
      final base = v['local']!;
      if (classes.every((c) => (v[c]! - base).abs() < 1e-6)) return base;
      return <dynamic>[
        'match',
        ['get', 'class'],
        ['motorway', 'motorway_link'],
        v['motorway'],
        ['trunk', 'trunk_link'],
        v['trunk'],
        ['primary', 'primary_link'],
        v['primary'],
        ['secondary', 'secondary_link', 'tertiary', 'tertiary_link'],
        v['secondary'],
        base,
      ];
    }

    final layers = <Map<String, dynamic>>[];
    for (final raw in (style['layers'] as List? ?? const [])) {
      final layer = Map<String, dynamic>.from(raw as Map);
      final id = '${layer['id'] ?? ''}'.toLowerCase();
      final source = '${layer['source'] ?? ''}';
      final sourceLayer = '${layer['source-layer'] ?? ''}'.toLowerCase();
      final isRoadLine = '${layer['type']}' == 'line' &&
          ((source == 'openmaptiles' &&
                  sourceLayer == 'transportation' &&
                  !id.contains('rail')) ||
              (source == 'abm-tiles' && sourceLayer == 'roads'));
      if (isRoadLine) {
        final paint = Map<String, dynamic>.from(
          (layer['paint'] as Map? ?? const {}).map((k, v) => MapEntry('$k', v)),
        );
        final width = paint['line-width'];
        if (width != null) {
          final stops = _widthStopZooms(width);
          final canSample = stops.isNotEmpty && _evalWidthAt(width, stops.first) != null;
          if (canSample) {
            final samples = <double>{...stops};
            for (var z = 8; z <= 22; z++) {
              samples.add(z.toDouble());
            }
            // نمونه‌ها فقط روی زوم‌های صحیح‌اند؛ ضریب داخل هر باند ثابت است و
            // بین آخرین زوم یک باند و اولین زوم باند بعدی (مثلاً ۱۳ تا ۱۴)
            // MapLibre به‌صورت خطی و نرم درون‌یابی می‌کند.
            final sorted = samples.toList()..sort();
            final expr = <dynamic>['interpolate', ['linear'], ['zoom']];
            for (final z in sorted) {
              final base = _evalWidthAt(width, z)!;
              final f = factorExprAt(z.floor());
              expr.add(z);
              expr.add(f is num ? double.parse((base * f).toStringAsFixed(4)) : <dynamic>['*', f, double.parse(base.toStringAsFixed(4))]);
            }
            paint['line-width'] = expr;
          } else {
            // Non-numeric curve: fall back to the base per-class factor.
            final v = <String, double>{for (final c in classes) c: clampK(widths[c] ?? 1.0)};
            paint['line-width'] = _scaleWidth(width, <dynamic>[
              'match', ['get', 'class'],
              ['motorway', 'motorway_link'], v['motorway'],
              ['trunk', 'trunk_link'], v['trunk'],
              ['primary', 'primary_link'], v['primary'],
              ['secondary', 'secondary_link', 'tertiary', 'tertiary_link'], v['secondary'],
              v['local'],
            ]);
          }
          layer['paint'] = paint;
        }
      }
      layers.add(layer);
    }
    style['layers'] = layers;
  }

  static final RegExp _paletteToken = RegExp(r'^\{\{(\w+)\}\}$');

  /// Replaces every `"{{name}}"` string with a colour: the user's palette
  /// wins, the style's own day/night default fills any gap.
  dynamic _resolveTokens(dynamic node, Map<String, String> palette) {
    if (node is String) {
      final match = _paletteToken.firstMatch(node);
      if (match == null) return node;
      final value = palette[match.group(1)!];
      if (value == null) throw StateError('Unknown style palette token: $node');
      return _hex(value);
    }
    if (node is List) {
      return node.map((e) => _resolveTokens(e, palette)).toList();
    }
    if (node is Map) {
      return node.map((k, v) => MapEntry('$k', _resolveTokens(v, palette)));
    }
    return node;
  }

  /// هر لایه‌ای که از `abm-tiles` می‌خواند برای هر نقشهٔ نصب‌شدهٔ اضافه در
  /// همان جایگاه تکثیر می‌شود (ترتیب لایه‌ها بین نقشه‌ها حفظ می‌شود: اول همهٔ
  /// casingها، بعد همهٔ lineها و ...).
  void _expandTileLayers(Map<String, dynamic> style, int count) {
    if (count <= 1) return;
    final out = <dynamic>[];
    for (final raw in (style['layers'] as List? ?? const [])) {
      out.add(raw);
      if (raw is! Map || raw['source'] != 'abm-tiles') continue;
      for (var i = 1; i < count; i++) {
        final copy = _copyStyle(Map<String, dynamic>.from(raw));
        copy['id'] = '${raw['id']}-m$i';
        copy['source'] = 'abm-tiles-$i';
        out.add(copy);
      }
    }
    style['layers'] = out;
  }

  /// Drops sources with no remaining layer reads. Offline mode therefore
  /// cannot accidentally retain an online OpenMapTiles source.
  void _pruneSources(Map<String, dynamic> style) {
    final used = <String>{};
    for (final raw in (style['layers'] as List? ?? const [])) {
      final source = (raw as Map)['source'];
      if (source != null) used.add('$source');
    }
    final sources = _asMap(style['sources']);
    sources.removeWhere((key, _) => !used.contains(key));
    style['sources'] = sources;
  }

  String? _currentStyleFile;
  String? _previousStyleFile;

  /// Writes the style under a name derived from its own content, so a
  /// different mode/theme/palette always means a different path -- the map
  /// widget is keyed on that path and rebuilds on change without the app
  /// having to be restarted. Only the current and the previous file are
  /// kept (the previous one may still be referenced while the widget swaps).
  Future<String> _writeStyle(Directory root, String body) async {
    final hash = sha1.convert(utf8.encode(body)).toString().substring(0, 12);
    final name = 'style_$hash.json';
    final file = File('${root.path}/$name');
    // Name is a content hash: an existing file is already identical. Rewriting
    // it in place can hand MapLibre a truncated style while it is reading it.
    if (!await file.exists() || await file.length() == 0) {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(file.path);
    }
    if (name != _currentStyleFile) {
      _previousStyleFile = _currentStyleFile;
      _currentStyleFile = name;
    }
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File) continue;
        final base = entity.uri.pathSegments.last;
        if (!base.startsWith('style_') || !base.endsWith('.json')) continue;
        if (base == _currentStyleFile || base == _previousStyleFile) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (error) {
      
    }
    return file.path;
  }

  /// Builds the style for the current state and returns its file path.
  /// [offline] selects the MBTiles-backed offline map mode.
  Future<String> resolve({
    required bool dark,
    required Map<String, String> colors,
    String? roadDirectionArrowColorHex,
    double? roadDirectionArrowSizePercent,
    Map<String, double> roadWidths = const {},
    Map<int, Map<String, double>> roadZoomWidths = const {},
    bool offline = false,
    String? mbtilesPath,
    List<String> mbtilesPaths = const <String>[],
  }) async {
    // همهٔ نقشه‌های نصب‌شده هم‌زمان رندر می‌شوند: هر mbtiles یک source جدا.
    final allMbtiles = <String>[
      if (mbtilesPath != null && mbtilesPath.isNotEmpty) mbtilesPath,
      for (final path in mbtilesPaths)
        if (path.isNotEmpty && path != mbtilesPath) path,
    ];
    mbtilesPath = allMbtiles.isEmpty ? null : allMbtiles.first;
    final root = await _ensureRoot();
    final raw = await rootBundle.loadString(_bundledStyle);
    final style = _copyStyle(jsonDecode(raw) as Map<String, dynamic>);

    // Map colours come exclusively from the Appearance/Map settings.
    // The bundled style intentionally contains no colour defaults.
    final palette = <String, String>{...colors};

    _selectMode(style, offline: offline);
    _localizeTextFields(style);
    _applyPalette(
      style,
      colors: palette,
      dark: dark,
      roadDirectionArrowColorHex: roadDirectionArrowColorHex,
      roadDirectionArrowSizePercent: roadDirectionArrowSizePercent,
    );
    _applyOnlinePalette(style, palette: palette, dark: dark);
    if (offline) {
      _applyOfflineOverrides(
        style,
        mbtilesPath: mbtilesPath,
      );
    }
    style['layers'] = _resolveTokens(style['layers'], palette);
    _applyRoadWidths(style, roadWidths, roadZoomWidths);
    _apply3dBuildings(style, palette['building']!);
    if (offline && mbtilesPath != null && mbtilesPath.isNotEmpty) {
      final sources = _asMap(style['sources']);
      final tileSource = _asMap(sources['abm-tiles']);
      tileSource['type'] = 'vector';
      final absoluteMbtiles = File(mbtilesPath).absolute.path;
      // Current Builder v3 produces a real vector MBTiles archive.
      // MapLibre Native consumes a local MBTiles file through the `mbtiles://`
      // source scheme with the absolute filesystem path directly after it.
      // The source URL must stay in the MapLibre `mbtiles://` scheme.
      // Flutter's MapLibre integration has documented
      // working examples using `mbtiles://<absolute-path>` for downloaded
      // files on device storage.
      tileSource['url'] = 'mbtiles://$absoluteMbtiles';
      tileSource.remove('tiles');
      // Diagnostic (off the UI thread, once per file): zoom coverage and which
      // layers/road classes the installed MBTiles really contains.
      for (final path in allMbtiles) {
        unawaited(_diagnoseMbtiles(path));
      }
      sources['abm-tiles'] = tileSource;
      for (var i = 1; i < allMbtiles.length; i++) {
        final extra = Map<String, dynamic>.from(tileSource);
        extra['url'] = 'mbtiles://${File(allMbtiles[i]).absolute.path}';
        sources['abm-tiles-$i'] = extra;
      }
      style['sources'] = sources;
      _expandTileLayers(style, allMbtiles.length);
    }
    // عوارض جاده‌ای (دوربین/محدودیت سرعت/سرعت‌گیر/هشدار): source + Symbol Layerها
    // با collision و minzoom/maxzoom داخل خودِ style. هر دو حالت online/offline.
    RoadHazards.applyToStyle(style);
    AbmSavedPlaces.applyToStyle(style);
    _pruneSources(style);
    _setLocalFontsAndAssets(style, root);

    style['metadata'] = <String, dynamic>{
      'abtin_maps_unified_style': true,
      'abtin_maps_offline_sources': offline,
      'abtin_maps_theme': dark ? 'night' : 'day',
      'abtin_maps_renderer': 'MapLibre Native',
    };

    final body = jsonEncode(style);
    final path = await _writeStyle(root, body);
    final labelLayers = (style['layers'] as List? ?? const [])
        .whereType<Map>()
        .where((l) => (l['layout'] as Map?)?.containsKey('text-field') == true)
        .map((l) => '${l['id']}(z${l['minzoom'] ?? 0},${(l['layout'] as Map)['symbol-placement'] ?? 'point'})')
        .join(',');
    final glyphOk = File('${root.path}/glyphs/Vazirmatn/1536-1791.pbf').existsSync();
    return path;
  }

  static final Set<String> _diagDone = <String>{};

  static Future<void> _diagnoseMbtiles(String path) async {
    if (!_diagDone.add(path)) return;
    try {
      final report = await Isolate.run(() => _mbtilesReport(path));
    } catch (error) {
    }
  }

  static String _mbtilesReport(String path) {
    final db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
    try {
      final meta = db
          .select("SELECT name, substr(value, 1, 1500) AS v FROM metadata "
              "WHERE name IN ('json','minzoom','maxzoom','format','name')")
          .map((r) => '${r['name']}=${r['v']}')
          .join(' | ');
      final zooms = db
          .select('SELECT zoom_level AS z, count(*) AS n FROM tiles '
              'GROUP BY zoom_level ORDER BY zoom_level')
          .map((r) => 'z${r['z']}:${r['n']}')
          .join(',');
      final maxRow = db.select('SELECT max(zoom_level) AS z FROM tiles');
      final maxZ = maxRow.isEmpty ? null : maxRow.first['z'];
      final needles = <String>[
        'roads', 'landuse', 'water', 'buildings', 'boundaries',
        'service', 'residential', 'unclassified', 'track', 'footway', 'path',
      ];
      final hits = <String, int>{for (final n in needles) n: 0};
      var sampled = 0;
      if (maxZ != null) {
        final rows = db.select(
          'SELECT tile_data FROM tiles WHERE zoom_level = ? LIMIT 300',
          [maxZ],
        );
        for (final row in rows) {
          List<int> bytes = (row['tile_data'] as List<int>);
          try {
            bytes = gzip.decode(bytes);
          } catch (_) {}
          final text = latin1.decode(bytes, allowInvalid: true);
          sampled++;
          for (final n in needles) {
            if (text.contains(n)) hits[n] = hits[n]! + 1;
          }
        }
      }
      return 'META $meta | TILES $zooms | SAMPLE z$maxZ n=$sampled '
          'tilesContaining=${hits.entries.map((e) => '${e.key}:${e.value}').join(',')}';
    } finally {
      db.dispose();
    }
  }

}
