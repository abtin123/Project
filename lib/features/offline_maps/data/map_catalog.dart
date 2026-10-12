import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:abtin_maps/core/geo/geo_types.dart';
import 'package:path_provider/path_provider.dart';

import '../../../abtinmap/abm_map_service.dart';

class MapDataSource {
  const MapDataSource({
    this.provider = 'Geofabrik / OpenStreetMap',
    this.url = '',
    this.attribution = 'Map data from OpenStreetMap, ODbL 1.0',
    this.licenseUrl = 'https://opendatacommons.org/licenses/odbl/1.0/',
    this.copyrightUrl = 'https://www.openstreetmap.org/copyright',
  });

  static const MapDataSource osm = MapDataSource();

  final String provider;
  final String url;
  final String attribution;
  final String licenseUrl;
  final String copyrightUrl;

  factory MapDataSource.fromJson(Map<String, dynamic> json) => MapDataSource(
        provider: (json['provider'] as String?) ?? osm.provider,
        url: (json['url'] as String?) ?? '',
        attribution: (json['attribution'] as String?) ?? osm.attribution,
        licenseUrl: (json['license_url'] as String?) ?? osm.licenseUrl,
        copyrightUrl: (json['copyright_url'] as String?) ?? osm.copyrightUrl,
      );
}

class VectorMapPackage {
  const VectorMapPackage({
    required this.dayStylePath,
    required this.nightStylePath,
    this.resources = const <String>[],
    this.embedded = true,
  });

  final String dayStylePath;
  final String nightStylePath;
  final List<String> resources;
  final bool embedded;

  List<String> get entryPaths => <String>[
        dayStylePath,
        nightStylePath,
        ...resources,
      ];

  bool get isUsable {
    final paths = entryPaths;
    return embedded &&
        _isSafeRelativePath(dayStylePath) &&
        dayStylePath.toLowerCase().endsWith('.json') &&
        _isSafeRelativePath(nightStylePath) &&
        nightStylePath.toLowerCase().endsWith('.json') &&
        resources.every(_isSafeRelativePath) &&
        paths.toSet().length == paths.length;
  }

  static bool _isSafeRelativePath(String value) {
    final normalized = value.replaceAll('\\', '/');
    return value.trim().isNotEmpty &&
        !normalized.startsWith('/') &&
        !normalized.contains('../') &&
        !normalized
            .split('/')
            .any((segment) => segment.isEmpty || segment == '.');
  }

  factory VectorMapPackage.fromJson(Map<String, dynamic> json) {
    String path(String key) {
      final value = json[key];
      if (value is String) return value;
      if (value is Map<String, dynamic> && value['path'] is String) {
        return value['path'] as String;
      }
      throw FormatException('فیلد vector_map.$key در manifest معتبر نیست.');
    }

    final rawResources = json['resources'];
    return VectorMapPackage(
      embedded: json['embedded'] == true,
      dayStylePath: path('day_style'),
      nightStylePath: path('night_style'),
      resources: rawResources is List
          ? rawResources.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }
}

class MapRegion {
  const MapRegion({
    required this.id,
    required this.name,
    required this.nameEn,
    required this.bounds,
    required this.version,
    this.routingBounds,
    this.routingOverlapDegrees = 0.0,
    this.countryCode = '',
    this.countryName = '',
    this.countryNameEn = '',
    this.regionName = '',
    this.regionNameEn = '',
    this.groupOrder = 0,
    this.files = const [],
    this.patch,
    this.totalSizeBytes = 0,
    this.downloadBase = '',
    this.bundledAsset = '',
    this.areaFactor = 1,
    this.source = MapDataSource.osm,
    this.vectorMap,
  });

  final String id;

  final String name;

  final String nameEn;

  final String countryCode;
  final String countryName;
  final String countryNameEn;

  final String regionName;
  final String regionNameEn;
  final int groupOrder;

  String get effectiveCountryCode => countryCode.isNotEmpty
      ? countryCode.toUpperCase()
      : id.substring(0, 2).toUpperCase();
  String displayCountryName(bool isEnglish) =>
      isEnglish && countryNameEn.isNotEmpty
          ? countryNameEn
          : countryName.isNotEmpty
              ? countryName
              : isEnglish
                  ? nameEn
                  : name;
  String displayRegionName(bool isEnglish) =>
      isEnglish && regionNameEn.isNotEmpty
          ? regionNameEn
          : regionName.isNotEmpty
              ? regionName
              : isEnglish
                  ? nameEn
                  : name;

  final LatLngBounds bounds;

  final LatLngBounds? routingBounds;
  final double routingOverlapDegrees;

  final String version;

  final List<AbmFilePart> files;

  final AbmMapPatch? patch;

  final int totalSizeBytes;

  final String downloadBase;

  final String bundledAsset;
  bool get isBundledAsset => bundledAsset.isNotEmpty;

  final double areaFactor;

  final MapDataSource source;

  final VectorMapPackage? vectorMap;

  String get abmFileName => '$id.abm';

  double get totalSizeMb => totalSizeBytes / (1024 * 1024);

  List<AbmFilePart> get effectiveFiles => files.isNotEmpty
      ? files
      : [AbmFilePart(name: abmFileName, size: totalSizeBytes, sha256: version)];

  String get effectiveDownloadBase =>
      downloadBase.isNotEmpty ? downloadBase : '$kAbmReleaseBase/';

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.contains(query.trim()) ||
        nameEn.toLowerCase().contains(q) ||
        countryName.contains(query.trim()) ||
        countryNameEn.toLowerCase().contains(q) ||
        regionName.contains(query.trim()) ||
        regionNameEn.toLowerCase().contains(q) ||
        id.toLowerCase().contains(q);
  }

  static LatLngBounds _boundsFromBbox(List<dynamic> raw) {
    final v = raw.map((e) => (e as num).toDouble()).toList();
    return LatLngBounds(
      southwest: LatLng(v[1], v[0]),
      northeast: LatLng(v[3], v[2]),
    );
  }

  factory MapRegion.fromJson(Map<String, dynamic> json,
      {String defaultDownloadBase = ''}) {
    final filesJson = (json['files'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AbmFilePart.fromJson)
        .toList();
    final rawPatch = json['patch'];
    final rawSource = json['source'];
    final rawVectorMap = json['vector_map'];
    final code = json['code'] as String;
    return MapRegion(
      id: code,
      name: (json['name_fa'] ?? code) as String,
      nameEn: (json['name_en'] ?? code) as String,
      countryCode: (json['country_code'] as String?) ?? code.substring(0, 2),
      countryName: (json['country_name_fa'] as String?) ??
          (json['name_fa'] ?? code) as String,
      countryNameEn: (json['country_name_en'] as String?) ??
          (json['name_en'] ?? code) as String,
      regionName: (json['region_name_fa'] as String?) ??
          (json['name_fa'] ?? code) as String,
      regionNameEn: (json['region_name_en'] as String?) ??
          (json['name_en'] ?? code) as String,
      groupOrder: (json['group_order'] as num?)?.toInt() ?? 0,
      bounds: _boundsFromBbox(json['bbox'] as List<dynamic>),
      version: (json['sha256'] ?? '') as String,
      routingBounds: json['routing_bbox'] is List
          ? _boundsFromBbox(json['routing_bbox'] as List<dynamic>)
          : null,
      routingOverlapDegrees:
          (json['routing_overlap_degrees'] as num?)?.toDouble() ?? 0.0,
      files: filesJson,
      patch: rawPatch is Map<String, dynamic>
          ? AbmMapPatch.fromJson(rawPatch)
          : null,
      totalSizeBytes: (json['total_size'] as num?)?.toInt() ?? 0,
      downloadBase: (json['download_base'] as String?) ?? defaultDownloadBase,
      source: rawSource is Map<String, dynamic>
          ? MapDataSource.fromJson(rawSource)
          : MapDataSource.osm,
      vectorMap: rawVectorMap is Map<String, dynamic>
          ? VectorMapPackage.fromJson(rawVectorMap)
          : null,
    );
  }

  factory MapRegion.fromInstalledFileOnly({
    required String id,
    required int fileSizeBytes,
  }) {
    final code = id.toUpperCase();
    return MapRegion(
      id: code,
      name: code,
      nameEn: code,
      countryCode: code.length >= 2 ? code.substring(0, 2) : code,
      totalSizeBytes: fileSizeBytes,
      version: '',
      bounds: const LatLngBounds(
        southwest: LatLng(-90, -180),
        northeast: LatLng(90, 180),
      ),
    );
  }
}

class MapCatalog {
  const MapCatalog({
    required this.regions,
    required this.fromNetwork,
    this.updatedAt,
  });

  final List<MapRegion> regions;

  final bool fromNetwork;
  final DateTime? updatedAt;

  MapRegion? byId(String id) {
    for (final region in regions) {
      if (region.id == id) return region;
    }
    return null;
  }
}

class MapCatalogService {
  MapCatalogService({String? manifestUrl, http.Client? client})
      : _manifestUrl = manifestUrl ?? defaultManifestUrl,
        _client = client ?? http.Client();

  static const String defaultManifestUrl = String.fromEnvironment(
    'ABTIN_MAP_MANIFEST_URL',
    defaultValue: kAbmManifestUrl,
  );

  final String _manifestUrl;
  final http.Client _client;
  MapCatalog? _memory;
  DateTime? _memoryLoadedAt;
  int _lastManualRefreshToken = 0;

  Future<MapCatalog> loadForRefreshToken(int token) {
    final forceRefresh = token > _lastManualRefreshToken;
    if (forceRefresh) _lastManualRefreshToken = token;
    return load(forceRefresh: forceRefresh);
  }

  Future<File> _cacheFile() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/map_catalog');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/manifest.json');
  }

  MapCatalog _parse(String body, {required bool fromNetwork}) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ساختار مانیفست نامعتبر است.');
    }
    final releaseTag = (decoded['release_tag'] as String?) ?? 'maps-v4';
    final defaultBase = kAbmReleaseBase.endsWith('/$releaseTag')
        ? '$kAbmReleaseBase/'
        : 'https://github.com/abtin123/abtin-maps/releases/download/$releaseTag/';
    final rawCountries = decoded['countries'];
    final items = <Map<String, dynamic>>[];
    if (rawCountries is List) {
      for (final item in rawCountries) {
        if (item is Map) {
          items.add(Map<String, dynamic>.from(item));
        }
      }
    } else if (rawCountries is Map) {
      for (final entry in rawCountries.entries) {
        if (entry.value is Map) {
          final item = Map<String, dynamic>.from(entry.value as Map);
          item.putIfAbsent('code', () => entry.key.toString());
          items.add(item);
        }
      }
    } else {
      throw const FormatException('فیلد countries در مانیفست معتبر نیست.');
    }
    final regions = <MapRegion>[];
    for (final item in items) {
      regions.add(MapRegion.fromJson(item, defaultDownloadBase: defaultBase));
    }
    final generatedAt = decoded['generated_at'];
    return MapCatalog(
      regions: regions,
      fromNetwork: fromNetwork,
      updatedAt: generatedAt is String ? DateTime.tryParse(generatedAt) : null,
    );
  }

  static const Duration _maxMemoryAge = Duration(minutes: 5);
  static const Duration _maxCacheAge = Duration(days: 1);

  Future<MapCatalog> load({bool forceRefresh = false}) async {
    if (!forceRefresh && _memory != null && _memoryLoadedAt != null &&
        DateTime.now().difference(_memoryLoadedAt!) < _maxMemoryAge) {
      return _memory!;
    }

    final cache = await _cacheFile();

    if (!forceRefresh) {
      try {
        if (cache.existsSync()) {
          final age = DateTime.now().difference(await cache.lastModified());
          if (age < _maxCacheAge) {
            final cached = await cache.readAsString(encoding: utf8);
            final catalog = _parse(cached, fromNetwork: false);
            _memory = catalog;
            _memoryLoadedAt = DateTime.now();
            return catalog;
          }
        }
      } catch (_) {
      }
    }

    try {
      var manifestUri = Uri.parse(_manifestUrl);
      if (forceRefresh) {
        manifestUri = manifestUri.replace(queryParameters: {
          ...manifestUri.queryParameters,
          '_ts': DateTime.now().millisecondsSinceEpoch.toString(),
        });
      }
      final response = await _client
          .get(manifestUri)
          .timeout(const Duration(seconds: 20));
      final bodyUtf8 = utf8.decode(response.bodyBytes);
      if (response.statusCode == 200 && bodyUtf8.length > 2) {
        final catalog = _parse(bodyUtf8, fromNetwork: true);
        await cache.writeAsString(bodyUtf8, flush: true, encoding: utf8);
        _memory = catalog;
        _memoryLoadedAt = DateTime.now();
        return catalog;
      }
      if (response.statusCode == 404) {
        _memory = null;
        _memoryLoadedAt = null;
        try {
          if (cache.existsSync()) await cache.delete();
        } catch (_) {}
        throw const FormatException('مانیفست نقشه در ریلیز maps-v4 پیدا نشد.');
      }

      
    } catch (error, stack) {
      if (error is FormatException &&
          error.message.contains('maps-v4')) {
        rethrow;
      }
      
    }

    try {
      if (cache.existsSync()) {
        final cached = await cache.readAsString(encoding: utf8);
        final catalog = _parse(cached, fromNetwork: false);
        _memory = catalog;
        _memoryLoadedAt = DateTime.now();
        return catalog;
      }
    } catch (error, stack) {
      
    }

    throw const FormatException('مانیفست نقشه در دسترس نیست.');
  }

  void dispose() => _client.close();
}
