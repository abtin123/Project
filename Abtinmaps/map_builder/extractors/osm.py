from __future__ import annotations
from collections.abc import Iterable
from abm_builder.core import entity_id, tags_dict, way_geometry, prepare_geometry

ROAD_CLASSES = {"motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
                "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
                "residential", "living_street", "road"}
# Roads that are drawn on the offline basemap but are NOT part of the search
# index (routing has its own class list in routing/graph_builder.py). Without
# these, service roads (terminal / parking / campus loops) and footways were
# missing from map.mbtiles even though the online style draws them.
RENDER_ONLY_ROAD_CLASSES = {"service", "track", "pedestrian", "footway", "path", "cycleway",
                            "steps", "bridleway", "busway"}
RENDER_ROAD_CLASSES = ROAD_CLASSES | RENDER_ONLY_ROAD_CLASSES

# Area features drawn in the `landuse` tile layer. Value = the class written to
# the tile's `landuse` attribute. Keys are (osm_key, osm_value).
# The four original classes keep their names so the existing style keeps working.
AREA_CLASSES = {
    ("landuse", "forest"): "forest", ("landuse", "farmland"): "farmland",
    ("landuse", "grass"): "grass", ("landuse", "residential"): "residential",
    ("landuse", "meadow"): "grass", ("landuse", "village_green"): "park",
    ("landuse", "recreation_ground"): "park", ("landuse", "orchard"): "farmland",
    ("landuse", "vineyard"): "farmland", ("landuse", "farmyard"): "farmland",
    ("landuse", "allotments"): "farmland", ("landuse", "greenfield"): "grass",
    ("landuse", "commercial"): "commercial", ("landuse", "retail"): "commercial",
    ("landuse", "industrial"): "industrial", ("landuse", "construction"): "industrial",
    ("landuse", "quarry"): "industrial", ("landuse", "railway"): "industrial",
    ("landuse", "garages"): "industrial", ("landuse", "military"): "military",
    ("landuse", "cemetery"): "cemetery", ("landuse", "religious"): "cemetery",
    ("landuse", "education"): "institutional", ("landuse", "institutional"): "institutional",
    ("landuse", "brownfield"): "industrial", ("landuse", "basin"): "water_area",
    ("leisure", "park"): "park", ("leisure", "garden"): "park",
    ("leisure", "playground"): "park", ("leisure", "dog_park"): "park",
    ("leisure", "common"): "park", ("leisure", "recreation_ground"): "park",
    ("leisure", "nature_reserve"): "forest", ("leisure", "golf_course"): "park",
    ("leisure", "pitch"): "pitch", ("leisure", "sports_centre"): "pitch",
    ("leisure", "stadium"): "pitch", ("leisure", "track"): "pitch",
    ("natural", "wood"): "forest", ("natural", "scrub"): "scrub",
    ("natural", "grassland"): "grass", ("natural", "heath"): "scrub",
    ("natural", "wetland"): "wetland", ("natural", "sand"): "sand",
    ("natural", "beach"): "sand", ("natural", "bare_rock"): "rock",
    ("natural", "scree"): "rock",
    ("amenity", "parking"): "parking", ("amenity", "bus_station"): "transport",
    ("amenity", "school"): "institutional", ("amenity", "university"): "institutional",
    ("amenity", "college"): "institutional", ("amenity", "hospital"): "institutional",
    ("amenity", "grave_yard"): "cemetery", ("amenity", "marketplace"): "commercial",
    ("aeroway", "aerodrome"): "transport", ("aeroway", "apron"): "transport",
    ("aeroway", "terminal"): "transport", ("public_transport", "station"): "transport",
    ("railway", "station"): "transport",
}
LANDUSE = {v for (k, v) in AREA_CLASSES if k == "landuse"}
POI_KEYS = {"hospital", "pharmacy", "fuel", "restaurant", "cafe", "bank", "school", "university", "police", "parking", "toilets", "supermarket", "mall", "convenience", "hotel", "attraction", "airport", "railway_station", "bus_station"}

SHOP_POI_KEYS = {"supermarket", "mall", "convenience"}

# Road-safety point categories: these live on the `highway`/`traffic_calming`
# keys (not `amenity`/`shop`/...), so pois() checks them separately below.
# Category names are written verbatim into map.sqlite's `categories` table and
# read back as-is by the app's offline RoadSafetyService, so they must match
# exactly: "speed_camera", "traffic_signals", "traffic_calming".
ROAD_SAFETY_HIGHWAY_KEYS = {"speed_camera", "traffic_signals"}

# Simplification tolerance per layer, in meters. Chosen well below anything
# visible on a phone screen at the zoom each layer is actually shown at
# (see _featureAllowedAtZoom / the buildings zoom<13 gate in the app):
#   - roads/water/boundaries are shown zoomed out a lot, so a few meters of
#     wobble on a bend is invisible but the point-count savings are large.
#   - buildings only ever render at zoom>=13 (close-up), so their tolerance
#     is kept tight to avoid visibly squaring off small structures.
# Routing correctness is unaffected either way: the routing graph is built
# separately from the source PBF (build_graph_from_pbf), never from these
# rendering-only geometries.
_TOLERANCE_M = {"roads": 1.0, "buildings": 1.0, "landuse": 4.0, "water": 2.0, "boundaries": 4.0}


def _record(obj, kind, geom_points, *, layer: str, tags: dict[str, str]):
    geom = prepare_geometry(geom_points, tolerance_m=_TOLERANCE_M.get(layer, 0.0), precision=6)
    # Drop empty/falsy values so a two-way road with no name doesn't carry
    # `"oneway":"no","bridge":"no","tunnel":"no"` (and friends) on every one
    # of a country's millions of road features - the app already treats a
    # missing tag as the same default those literal "no"s spelled out.
    clean_tags = {k: v for k, v in tags.items() if v not in ("", None)}
    # `kind`/`type` ("Road", "Building", ...) is never read by the app - it
    # infers layer from which vector/<layer>/*.bin file a chunk came from -
    # so it is not written to disk at all.
    del kind
    return {"id": entity_id(obj), "geometry": geom, "tags": clean_tags}


def roads(ways: Iterable):
    for w in ways:
        t = tags_dict(w); highway = t.get("highway", "")
        if highway in RENDER_ROAD_CLASSES:
            oneway = t.get("oneway", "")
            bridge = t.get("bridge", "")
            tunnel = t.get("tunnel", "")
            yield _record(w, "Road", way_geometry(w), layer="roads", tags={
                "highway": highway,
                "name": t.get("name", ""), "name_fa": t.get("name:fa", ""), "name_en": t.get("name:en", ""),
                "oneway": oneway if oneway != "no" else "",
                "bridge": bridge if bridge != "no" else "",
                "tunnel": tunnel if tunnel != "no" else "",
                "layer": t.get("layer", ""),
                "maxspeed": t.get("maxspeed", ""), "access": t.get("access", ""),
                "service": t.get("service", ""),
            })


def buildings(ways: Iterable):
    for w in ways:
        t = tags_dict(w)
        if "building" in t:
            geom = way_geometry(w)
            if len(geom) > 3:
                area = abs(sum(geom[i][0]*geom[(i+1)%len(geom)][1]-geom[(i+1)%len(geom)][0]*geom[i][1] for i in range(len(geom))))/2
                if area * 111320 * 111320 < 30:
                    continue
            yield _record(w, "Building", geom, layer="buildings", tags={
                "building": t.get("building", "yes"),
                **{k: t[k] for k in ("height", "min_height", "building:levels",
                                     "building:min_level", "roof:height") if t.get(k)},
            })


def landuse(ways: Iterable):
    for w in ways:
        t = tags_dict(w)
        cls = ""
        for key in ("landuse", "leisure", "natural", "amenity", "aeroway", "public_transport", "railway"):
            cls = AREA_CLASSES.get((key, t.get(key, "")), "")
            if cls:
                break
        if not cls or cls == "water_area":
            continue
        geom = way_geometry(w)
        # Only closed rings are areas (a linear `railway=station` etc. is not).
        if len(geom) < 4 or geom[0] != geom[-1]:
            continue
        yield _record(w, "Landuse", geom, layer="landuse", tags={"landuse": cls})


def water(ways: Iterable):
    for w in ways:
        t = tags_dict(w)
        natural, waterway = t.get("natural", ""), t.get("waterway", "")
        if natural in {"water", "coastline"} or waterway in {"river", "stream", "canal"}:
            # Keep the two source keys distinct (not collapsed into one
            # "water_type") - the app tells a water polygon (lake/sea) from a
            # waterway line (river/stream) by whether `waterway` is present.
            yield _record(w, "Water", way_geometry(w), layer="water", tags={
                "natural": natural, "waterway": waterway,
            })


def boundaries(ways: Iterable, relations: Iterable = ()):
    for obj in list(ways) + list(relations):
        t = tags_dict(obj)
        if t.get("boundary") == "administrative":
            yield _record(obj, "Boundary", way_geometry(obj), layer="boundaries", tags={
                "admin_level": t.get("admin_level", ""), "name": t.get("name", ""),
            })


def places(nodes: Iterable, ways: Iterable = ()):
    for obj in list(nodes) + list(ways):
        t = tags_dict(obj)
        if t.get("place") in {"city", "town", "village", "neighbourhood", "suburb", "hamlet"}:
            geom = way_geometry(obj) if hasattr(obj, "nodes") or isinstance(obj, dict) and obj.get("geometry") else []
            if not geom:
                lat, lon = getattr(obj, "lat", None), getattr(obj, "lon", None)
                if isinstance(obj, dict): lat, lon = obj.get("lat", lat), obj.get("lon", lon)
                geom = [(float(lon), float(lat))] if lat is not None and lon is not None else []
            yield _record(obj, "Place", geom, layer="places", tags={
                "place": t["place"], "name": t.get("name", ""),
                "name_fa": t.get("name:fa", ""), "name_en": t.get("name:en", ""),
            })


def pois(nodes: Iterable, ways: Iterable = ()):
    for obj in list(nodes) + list(ways):
        t = tags_dict(obj); value = ""
        for key in ("amenity", "shop", "tourism", "aeroway", "railway", "public_transport"):
            v = t.get(key)
            if key == "shop" and v == "fuel":
                # shop=fuel = shop selling heating/cooking fuel (charcoal, firewood,
                # kerosene, bottled gas). It is a general shop, NOT a vehicle fuel
                # station (amenity=fuel), so it gets its own category which the app
                # renders with the shop (supermarket) icon.
                value = "shop_fuel"; break
            if v not in POI_KEYS: continue
            if key == "shop" and v not in SHOP_POI_KEYS: continue
            value = v; break
        if not value and t.get("highway") in ROAD_SAFETY_HIGHWAY_KEYS:
            # Speed cameras and traffic signals are tagged as highway=*, not
            # amenity=*, so they never matched the loop above. Offline
            # road-safety alerts (RoadSafetyService.offline in the app) read
            # exactly these two category names near the driver's position.
            value = t["highway"]
        if not value and "traffic_calming" in t:
            # Speed bumps/humps: presence of the key matters, the value
            # ("bump", "hump", "table", ...) does not - the app treats any
            # traffic_calming node as one speedBump alert.
            value = "traffic_calming"
        if not value: continue
        lat, lon = getattr(obj, "lat", None), getattr(obj, "lon", None)
        if isinstance(obj, dict): lat, lon = obj.get("lat", lat), obj.get("lon", lon)
        if lat is None or lon is None:
            geom = way_geometry(obj)
            if not geom: continue
            lon, lat = sum(x for x, _ in geom) / len(geom), sum(y for _, y in geom) / len(geom)
        yield {"id": entity_id(obj), "name": t.get("name", ""), "name_fa": t.get("name:fa", ""), "name_en": t.get("name:en", ""), "category": value, "latitude": float(lat), "longitude": float(lon), "opening_hours": t.get("opening_hours", "")}
