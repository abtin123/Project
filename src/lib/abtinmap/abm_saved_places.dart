abstract final class AbmSavedPlaces {
  static const sourceId = 'abm-saved-places';
  static const layerId = 'abm-saved-places-symbols';
  static const homeWorkLayerId = 'abm-saved-places-homework';

  static void applyToStyle(Map<String, dynamic> style) {
    final sources = Map<String, dynamic>.from(
      (style['sources'] as Map?)?.map((k, v) => MapEntry('$k', v)) ??
          const <String, dynamic>{},
    );
    sources[sourceId] = <String, dynamic>{
      'type': 'geojson',
      'data': <String, dynamic>{
        'type': 'FeatureCollection',
        'features': <dynamic>[],
      },
    };
    style['sources'] = sources;

    final layers = List<dynamic>.from(style['layers'] as List? ?? const []);
    layers.removeWhere((layer) =>
        layer is Map && (layer['id'] == layerId || layer['id'] == homeWorkLayerId));

    var at = layers.indexWhere((layer) =>
        layer is Map && '${layer['id']}'.startsWith('abm-hz-'));
    if (at < 0) at = layers.length;
    layers.insert(at, <String, dynamic>{
      'id': layerId,
      'type': 'symbol',
      'source': sourceId,
      'filter': <dynamic>[
        '!',
        <dynamic>[
          'in',
          <dynamic>['get', 'category'],
          <dynamic>['literal', <String>['home', 'work']],
        ],
      ],
      'minzoom': 10,
      'maxzoom': 24,
      'layout': <String, dynamic>{
        'icon-image': 'abm-hz-saved_place',
        'icon-size': <dynamic>[
          'interpolate',
          <dynamic>['linear'],
          <dynamic>['zoom'],
          10, 0.42,
          13, 0.54,
          16, 0.70,
          19, 0.84,
        ],
        'icon-allow-overlap': false,
        'icon-ignore-placement': false,
        'icon-optional': false,
        'icon-padding': 8,
        'icon-pitch-alignment': 'viewport',
        'icon-rotation-alignment': 'viewport',
        'symbol-sort-key': 90,
      },
      'paint': <String, dynamic>{
        'icon-opacity': <dynamic>[
          'interpolate',
          <dynamic>['linear'],
          <dynamic>['zoom'],
          10, 0.78,
          14, 0.94,
          17, 1.0,
        ],
      },
    });
    layers.insert(at + 1, <String, dynamic>{
      'id': homeWorkLayerId,
      'type': 'symbol',
      'source': sourceId,
      'filter': <dynamic>[
        'in',
        <dynamic>['get', 'category'],
        <dynamic>['literal', <String>['home', 'work']],
      ],
      'minzoom': 4,
      'maxzoom': 24,
      'layout': <String, dynamic>{
        'icon-image': <dynamic>[
          'match',
          <dynamic>['get', 'category'],
          'home', 'abm-hz-home',
          'work', 'abm-hz-work',
          'abm-hz-saved_place',
        ],
        'icon-size': <dynamic>[
          'interpolate',
          <dynamic>['linear'],
          <dynamic>['zoom'],
          4, 0.22,
          8, 0.30,
          12, 0.38,
          16, 0.46,
          19, 0.56,
        ],
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
        'icon-pitch-alignment': 'viewport',
        'icon-rotation-alignment': 'viewport',
        'symbol-sort-key': 95,
      },
    });
    style['layers'] = layers;
  }

  static Map<String, dynamic> compose(List<AbmSavedPlace> places) {
    final seen = <String>{};
    final features = <Map<String, dynamic>>[];
    final ordered = <AbmSavedPlace>[
      ...places.where((p) => p.category == 'home' || p.category == 'work'),
      ...places.where((p) => p.category != 'home' && p.category != 'work'),
    ];
    for (final place in ordered) {
      if (!place.latitude.isFinite || !place.longitude.isFinite) continue;
      final key =
          '${place.latitude.toStringAsFixed(6)},${place.longitude.toStringAsFixed(6)}';
      if (!seen.add(key)) continue;
      features.add(<String, dynamic>{
        'type': 'Feature',
        'geometry': <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[place.longitude, place.latitude],
        },
        'properties': <String, dynamic>{
          'name': place.name,
          'category': place.category,
          'saved': true,
        },
      });
    }
    return <String, dynamic>{
      'type': 'FeatureCollection',
      'features': features,
    };
  }
}

class AbmSavedPlace {
  const AbmSavedPlace({
    required this.latitude,
    required this.longitude,
    required this.name,
    this.category = 'favorite',
  });

  final double latitude;
  final double longitude;
  final String name;
  final String category;
}
