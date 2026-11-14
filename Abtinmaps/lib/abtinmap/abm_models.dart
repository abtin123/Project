import 'dart:math' as math;

class AbmKlass {
  static const motorway = 1;
  static const trunk = 2;
  static const primary = 3;
  static const secondary = 4;
  static const tertiary = 5;
  static const residential = 6;
  static const service = 7;
  static const unclassified = 8;
  static const track = 9;
  static const footway = 10;
  static const cycleway = 11;
  static const steps = 12;

  static const railway = 20;
  static const waterArea = 30;
  static const waterway = 31;
  static const green = 32;
  static const urban = 33;
  static const building = 34;
  static const boundary = 40;

  static const poiFuel = 50;
  static const poiParking = 51;
  static const poiHospital = 52;
  static const poiPharmacy = 53;
  static const poiPolice = 54;
  static const poiSchool = 55;
  static const poiRestaurant = 56;
  static const poiCafe = 57;
  static const poiBank = 58;
  static const poiHotel = 59;
  static const poiSupermarket = 60;
  static const poiMosque = 61;
  static const poiToilets = 62;
  static const poiBusStation = 63;
  static const poiAirport = 64;
  static const poiAttraction = 65;
  static const poiPark = 66;
  static const poiPitch = 67;
  static const poiPlace = 68;

  static const poiSpeedCamera = 70;

  static const poiSpeedBump = 71;

  static const poiTrafficLight = 72;

  static const List<int> selectablePoiKlasses = [
    poiFuel,
    poiParking,
    poiHospital,
    poiPharmacy,
    poiPolice,
    poiSchool,
    poiRestaurant,
    poiCafe,
    poiBank,
    poiHotel,
    poiSupermarket,
    poiMosque,
    poiToilets,
    poiBusStation,
    poiAirport,
    poiAttraction,
    poiPark,
    poiPitch,
    poiPlace,
    poiSpeedCamera,
    poiSpeedBump,
    poiTrafficLight,
  ];
}

class AbmWidthEstimate {
  static const Map<int, double> _byKlass = {
    AbmKlass.motorway: 15.0,
    AbmKlass.trunk: 12.0,
    AbmKlass.primary: 9.0,
    AbmKlass.secondary: 7.5,
    AbmKlass.tertiary: 6.5,
    AbmKlass.residential: 6.0,
    AbmKlass.unclassified: 5.0,
    AbmKlass.service: 3.5,
    AbmKlass.track: 2.5,
  };

  static double metersFor(int klass, {bool surfaceUnpaved = false}) {
    final base = _byKlass[klass] ?? 2.0;
    return surfaceUnpaved ? base * 0.8 : base;
  }
}

class AbmAttr {
  static const onewayForward = 1 << 0; // حرکت در جهت رو به جلو ممنوع
  static const onewayBackward = 1 << 1; // حرکت در جهت معکوس ممنوع
  static const bridge = 1 << 2;
  static const tunnel = 1 << 3;
  static const roundabout = 1 << 4;
  static const link = 1 << 5;
  static const toll = 1 << 6;
  static const surfaceUnpaved = 1 << 7;
  static const reversed = 1 << 8;
  static const noAccess = 1 << 9;
  static const junctionNamed = 1 << 10;
  static const explicitMaxspeed = 1 << 11;
}

class AbmPoint {
  const AbmPoint(this.lon, this.lat);
  final double lon;
  final double lat;

  @override
  String toString() => '($lon, $lat)';
}

class AbmWay {
  AbmWay({
    required this.klass,
    required this.attr,
    required this.minZoom,
    required this.name,
    required this.speedCode,
    required this.refs,
    this.widthDm = 0,
  });

  final int klass;
  final int attr;
  final int minZoom;
  final String name;
  final int speedCode;

  final int widthDm;

  final List<int> refs;

  bool get isRoundabout => (attr & AbmAttr.roundabout) != 0;
  bool get isLink => (attr & AbmAttr.link) != 0;

  bool get isSurfaceUnpaved => (attr & AbmAttr.surfaceUnpaved) != 0;

  bool get hasRealWidth => widthDm > 0;

  double get estimatedWidthMeters => hasRealWidth
      ? widthDm / 10.0
      : AbmWidthEstimate.metersFor(klass, surfaceUnpaved: isSurfaceUnpaved);

  int? get speedLimitKmh {
    if (speedCode >= 1 && speedCode <= 40) return speedCode * 5;
    if (speedCode == 200) return 50; // پیش‌فرض شهری ایران
    if (speedCode == 201) {
      switch (klass) {
        case AbmKlass.motorway:
          return 120;
        case AbmKlass.trunk:
          return 100;
        case AbmKlass.primary:
          return 90;
        case AbmKlass.secondary:
          return 80;
        default:
          return 70;
      }
    }
    return null; // 0 = نامشخص، 255 = بی‌محدودیت
  }
}

class AbmEdge {
  const AbmEdge(this.wayIndex, this.a, this.b, this.forward10, this.backward10);
  final int wayIndex;
  final int a;
  final int b;
  final int forward10;
  final int backward10;
}

class AbmArea {
  AbmArea({
    required this.klass,
    required this.attr,
    required this.minZoom,
    required this.name,
    required this.rings,
  });

  final int klass;
  final int attr;
  final int minZoom;
  final String name;
  final List<List<AbmPoint>> rings;
}

class AbmPoi {
  AbmPoi({
    required this.point,
    required this.klass,
    required this.minZoom,
    required this.name,
  });

  final AbmPoint point;
  final int klass;
  final int minZoom;
  final String name;
}

class AbmTile {
  AbmTile({
    required this.z,
    required this.x,
    required this.y,
    required this.origin,
  });

  final int z;
  final int x;
  final int y;
  final AbmPoint origin;

  final List<AbmPoint> nodes = [];
  final List<AbmWay> ways = [];
  final List<AbmEdge> edges = [];
  final List<AbmArea> areas = [];
  final List<AbmPoi> pois = [];

  final Map<int, int> border = {};
}

class AbmTileMath {
  static const double maxLat = 85.05112878;

  static double haversineMeters(AbmPoint a, AbmPoint b) {
    const r = 6371000.0;
    final dLat = (b.lat - a.lat) * math.pi / 180;
    final dLon = (b.lon - a.lon) * math.pi / 180;
    final la1 = a.lat * math.pi / 180;
    final la2 = b.lat * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  static double bearing(AbmPoint from, AbmPoint to) {
    final lat1 = from.lat * math.pi / 180;
    final lat2 = to.lat * math.pi / 180;
    final dLon = (to.lon - from.lon) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}
