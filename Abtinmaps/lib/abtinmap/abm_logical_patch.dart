// Logical (row-level) map patch: ABTINMAP-LOGICAL-PATCH/1.
//
// Mirror of builder/release_packaging/logical_patch.py - keep both in sync
// (apply order, SQL, digest format). Applies the patch to the extracted
// SQLite/MBTiles stores of the installed .abm, verifies the result against the
// manifest's `target_digest` (SHA-256 over the resolved content, independent of
// ids / page layout) and repacks a new .abm container.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

const String kAbmLogicalPatchSchema = 'ABTINMAP-LOGICAL-PATCH/1';
const int _kLogicalSpec = 1;

class AbmLogicalPatchException implements Exception {
  const AbmLogicalPatchException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AbmLogicalPatchManifest {
  const AbmLogicalPatchManifest({
    required this.code,
    required this.baseSha256,
    required this.targetSha256,
    required this.patchSha256,
    required this.targetDigest,
    required this.sqliteMember,
    required this.mbtilesMember,
  });

  final String code;
  final String baseSha256;
  final String targetSha256;
  final String patchSha256;
  final String targetDigest;
  final String sqliteMember;
  final String mbtilesMember;

  static bool matches(Map<String, dynamic> json) =>
      json['schema'] == kAbmLogicalPatchSchema;

  factory AbmLogicalPatchManifest.fromJson(Map<String, dynamic> json) {
    if (!matches(json) || json['spec'] != _kLogicalSpec) {
      throw const AbmLogicalPatchException('نسخهٔ patch منطقی پشتیبانی نمی‌شود.');
    }
    String s(String key) => (json[key] as String?) ?? '';
    final m = AbmLogicalPatchManifest(
      code: s('code'),
      baseSha256: s('base_sha256'),
      targetSha256: s('target_sha256'),
      patchSha256: s('patch_sha256'),
      targetDigest: s('target_digest'),
      sqliteMember: s('sqlite_member'),
      mbtilesMember: s('mbtiles_member'),
    );
    bool safe(String n, String ext) =>
        n.isNotEmpty && n == p.basename(n) && n.toLowerCase().endsWith(ext);
    if (m.targetDigest.length != 64 ||
        !safe(m.sqliteMember, '.sqlite') ||
        !safe(m.mbtilesMember, '.mbtiles')) {
      throw const AbmLogicalPatchException('مشخصات patch منطقی نامعتبر است.');
    }
    return m;
  }

  Map<String, String> toMap() => {
        'sqlite': sqliteMember,
        'mbtiles': mbtilesMember,
        'digest': targetDigest,
      };
}

class AbmLogicalPatch {
  /// Applies [patchFile] to the installed [baseAbm] and writes the rebuilt
  /// archive to [output] (any exception means: caller falls back to the full
  /// download). Runs in a background isolate.
  static Future<void> apply({
    required File baseAbm,
    required File patchFile,
    required AbmLogicalPatchManifest manifest,
    required File output,
  }) {
    final basePath = baseAbm.path;
    final patchPath = patchFile.path;
    final outPath = output.path;
    final args = manifest.toMap();
    return Isolate.run(() => _applySync(basePath, patchPath, args, outPath));
  }
}

// ----------------------------------------------------------------- digest
class _DigestSection {
  const _DigestSection(this.name, this.db, this.sql);
  final String name;
  final String db; // 'sqlite' | 'mbtiles'
  final String sql;
}

// Generated from SECTIONS + DIGEST_ONLY in logical_patch.py (way_segments is
// covered by segments_flat/pieces_flat).
const List<_DigestSection> _digestSections = [
  _DigestSection('features', 'sqlite',
      'SELECT f.id, f.kind, n.name, n.name_fa, n.name_en, c.name, f.opening_hours, s.min_lon, s.max_lon, s.min_lat, s.max_lat FROM features f JOIN categories c ON c.id = f.category_id LEFT JOIN names n ON n.id = f.name_id LEFT JOIN spatial s ON s.id = f.id ORDER BY f.id'),
  _DigestSection('node_data', 'sqlite',
      'SELECT id, lat_e7, lon_e7, cell_id FROM node_data ORDER BY id'),
  _DigestSection('way_data', 'sqlite',
      'SELECT w.way_id, c.name, n.name, n.name_fa, n.name_en, w.access, w.junction, w.surface, w.speed_kmh, w.oneway, w.lanes, w.flags, w.turn_lanes, w.turn_lanes_bwd FROM way_data w JOIN categories c ON c.id = w.class_id LEFT JOIN names n ON n.id = w.name_id ORDER BY w.way_id'),
  _DigestSection('way_geometry', 'sqlite',
      'SELECT way_id, encoding, geometry FROM way_geometry ORDER BY way_id'),
  _DigestSection('roundabout_info', 'sqlite',
      'SELECT r.way_id, r.junction, e.a, e.b, e.way_id, x.a, x.b, x.way_id, r.exit_number, r.exit_count FROM roundabout_info r LEFT JOIN segments e ON e.id = r.entry_edge LEFT JOIN segments x ON x.id = r.exit_edge ORDER BY r.way_id'),
  _DigestSection('routing_cells', 'sqlite',
      'SELECT cell_id, min_lon, min_lat, max_lon, max_lat, node_count, edge_count FROM routing_cells ORDER BY cell_id'),
  _DigestSection('turn_restrictions', 'sqlite',
      'SELECT id, restriction, from_json, via_json, to_json FROM turn_restrictions ORDER BY id'),
  _DigestSection('turn_restriction_lookup', 'sqlite',
      'SELECT restriction_id, from_way, via_node, to_way, restriction FROM turn_restriction_lookup ORDER BY restriction_id, from_way, via_node, to_way'),
  _DigestSection('mbtiles_metadata', 'mbtiles',
      'SELECT name, value FROM metadata ORDER BY name'),
  _DigestSection('tiles', 'mbtiles',
      'SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles ORDER BY zoom_level, tile_column, tile_row'),
  _DigestSection('node_index', 'sqlite',
      'SELECT id, min_lon, max_lon, min_lat, max_lat FROM node_index ORDER BY id'),
  _DigestSection('segments_flat', 'sqlite',
      'SELECT way_id, ROW_NUMBER() OVER (PARTITION BY way_id ORDER BY id) - 1, a, b, dist_dm, cell_id FROM segments ORDER BY way_id, id'),
  _DigestSection('pieces_flat', 'sqlite',
      'WITH f AS (SELECT id, way_id, ROW_NUMBER() OVER (PARTITION BY way_id ORDER BY id) - 1 AS ord FROM segments) SELECT f.way_id, f.ord, g.ord, r.min_lon, r.max_lon, r.min_lat, r.max_lat FROM road_index r JOIN f ON f.id = r.seg_from JOIN f g ON g.id = r.seg_to ORDER BY f.way_id, f.ord'),
  _DigestSection('hierarchy_edges', 'sqlite',
      'SELECT s.a, s.b, s.way_id, h.level FROM hierarchy_edges h JOIN segments s ON s.id = h.edge_id ORDER BY s.a, s.b, s.way_id, h.level'),
];

const String _hierarchySql =
    "INSERT INTO hierarchy_edges(level, edge_id) SELECT CASE WHEN c.name = 'motorway' THEN 3 WHEN c.name IN ('trunk','motorway_link','trunk_link') THEN 2 WHEN c.name IN ('primary','primary_link','secondary','secondary_link') THEN 1 ELSE 0 END, s.id FROM segments s JOIN way_data w ON w.way_id = s.way_id JOIN categories c ON c.id = w.class_id";
const String _nodeIndexSql =
    'INSERT INTO node_index(id, min_lon, max_lon, min_lat, max_lat) SELECT id, lon_e7*1e-7, lon_e7*1e-7, lat_e7*1e-7, lat_e7*1e-7 FROM node_data WHERE id = ?';

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _Hasher {
  _Hasher() {
    _conv = sha256.startChunkedConversion(_sink);
  }
  final _DigestSink _sink = _DigestSink();
  late final ByteConversionSink _conv;
  void add(List<int> bytes) => _conv.add(bytes);
  String finish() {
    _conv.close();
    return _sink.value.toString();
  }
}

String _hex(List<int> bytes) {
  final b = StringBuffer();
  for (final v in bytes) {
    b.write(v.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// Same canonical text as `_fmt` in logical_patch.py.
String _fmt(Object? v) {
  if (v == null) return 'N';
  if (v is int) return 'i$v';
  if (v is double) {
    final bd = ByteData(8)..setFloat64(0, v, Endian.big);
    return 'f${_hex(bd.buffer.asUint8List())}';
  }
  if (v is String) return 's${utf8.encode(v).length}:$v';
  return 'b${_hex(v as List<int>)}';
}

String _contentDigest(sqlite.Database sq, sqlite.Database mb) {
  final sections = <String, String>{};
  for (final sec in _digestSections) {
    final db = sec.db == 'sqlite' ? sq : mb;
    final h = _Hasher();
    final stmt = db.prepare(sec.sql);
    try {
      final cursor = stmt.selectCursor();
      if (sec.name == 'tiles') {
        while (cursor.moveNext()) {
          final row = cursor.current;
          final blob = row.columnAt(3) as Uint8List;
          h.add(utf8.encode(
              '${row.columnAt(0)},${row.columnAt(1)},${row.columnAt(2)},${blob.length}\n'));
          h.add(blob);
        }
      } else {
        final n = cursor.columnNames.length;
        while (cursor.moveNext()) {
          final row = cursor.current;
          final parts = <String>[];
          for (var i = 0; i < n; i++) {
            parts.add(_fmt(row.columnAt(i)));
          }
          h.add(utf8.encode('${parts.join(',')}\n'));
        }
      }
    } finally {
      stmt.dispose();
    }
    sections[sec.name] = h.finish();
  }
  final names = sections.keys.toList()..sort();
  final ordered = names.map((k) => '$k=${sections[k]}').join('\n');
  return sha256.convert(utf8.encode(ordered)).toString();
}

// ----------------------------------------------------------------- apply
class _Applier {
  _Applier(this.sq, this.mb) {
    for (final r in sq.select('SELECT id, name FROM categories')) {
      _cats[r['name'] as String] = r['id'] as int;
    }
    sq.execute(
        'CREATE INDEX IF NOT EXISTS ix_apply_names ON names(name, name_fa, name_en)');
  }

  final sqlite.Database sq;
  final sqlite.Database mb;
  final Map<String, int> _cats = {};
  final Map<String, int?> _names = {};
  final Map<String, sqlite.PreparedStatement> _sqStmts = {};
  final Map<String, sqlite.PreparedStatement> _mbStmts = {};
  bool hierarchy = false;
  bool segIndex = false;

  void _run(sqlite.Database db, String sql, [List<Object?> params = const []]) {
    final cache = identical(db, sq) ? _sqStmts : _mbStmts;
    cache.putIfAbsent(sql, () => db.prepare(sql)).execute(params);
  }

  List<List<Object?>> _all(sqlite.Database db, String sql, List<Object?> params) {
    final cache = identical(db, sq) ? _sqStmts : _mbStmts;
    final rs = cache.putIfAbsent(sql, () => db.prepare(sql)).select(params);
    return [for (final r in rs) List<Object?>.from(r.values)];
  }

  int _category(String name) {
    final hit = _cats[name];
    if (hit != null) return hit;
    _run(sq, 'INSERT INTO categories(name) VALUES (?)', [name]);
    return _cats[name] = sq.lastInsertRowId;
  }

  int? _name(Object? n, Object? fa, Object? en) {
    if (n == null) return null;
    final key = jsonEncode([n, fa, en]);
    if (_names.containsKey(key)) return _names[key];
    final found = _all(
        sq,
        'SELECT id FROM names WHERE name = ? AND name_fa = ? AND name_en = ? LIMIT 1',
        [n, fa, en]);
    int id;
    if (found.isNotEmpty) {
      id = found.first[0] as int;
    } else {
      _run(sq, 'INSERT INTO names(name, name_fa, name_en) VALUES (?,?,?)',
          [n, fa, en]);
      id = sq.lastInsertRowId;
      _run(sq,
          'INSERT INTO search_fts(rowid, name, name_fa, name_en) VALUES (?,?,?,?)',
          [id, n, fa, en]);
    }
    return _names[key] = id;
  }

  int? _segId(Object? a, Object? b, Object? way) {
    if (a == null) return null;
    final r = _all(sq,
        'SELECT id FROM segments WHERE a = ? AND b = ? AND way_id = ?',
        [a, b, way]);
    return r.isEmpty ? null : r.first[0] as int;
  }

  void rows(String table, String kind, List<dynamic> rows) {
    final isDel = kind == 'del';
    for (final raw in rows) {
      final r = raw as List<dynamic>;
      switch (table) {
        case 'features':
          if (isDel) {
            _run(sq, 'DELETE FROM features WHERE id = ?', [r[0]]);
            _run(sq, 'DELETE FROM spatial WHERE id = ?', [r[0]]);
            break;
          }
          _run(sq,
              'INSERT OR REPLACE INTO features(id, kind, name_id, category_id, opening_hours) VALUES (?,?,?,?,?)',
              [r[0], r[1], _name(r[2], r[3], r[4]), _category(r[5] as String), r[6]]);
          _run(sq, 'DELETE FROM spatial WHERE id = ?', [r[0]]);
          if (r[7] != null) {
            _run(sq,
                'INSERT INTO spatial(id, min_lon, max_lon, min_lat, max_lat) VALUES (?,?,?,?,?)',
                [r[0], r[7], r[8], r[9], r[10]]);
          }
          break;
        case 'node_data':
          _run(sq, 'DELETE FROM node_index WHERE id = ?', [r[0]]);
          if (isDel) {
            _run(sq, 'DELETE FROM node_data WHERE id = ?', [r[0]]);
            break;
          }
          _run(sq,
              'INSERT OR REPLACE INTO node_data(id, lat_e7, lon_e7, cell_id) VALUES (?,?,?,?)',
              [r[0], r[1], r[2], r[3]]);
          _run(sq, _nodeIndexSql, [r[0]]);
          break;
        case 'way_data':
          hierarchy = true;
          if (isDel) {
            _run(sq, 'DELETE FROM way_data WHERE way_id = ?', [r[0]]);
            break;
          }
          _run(sq,
              'INSERT OR REPLACE INTO way_data(way_id, class_id, name_id, access, junction, surface, speed_kmh, oneway, lanes, flags, turn_lanes, turn_lanes_bwd) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
              [
                r[0],
                _category(r[1] as String),
                _name(r[2], r[3], r[4]),
                r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13],
              ]);
          break;
        case 'way_geometry':
          if (isDel) {
            _run(sq, 'DELETE FROM way_geometry WHERE way_id = ?', [r[0]]);
            break;
          }
          _run(sq,
              'INSERT OR REPLACE INTO way_geometry(way_id, encoding, geometry) VALUES (?,?,?)',
              [r[0], r[1], base64Decode(r[2] as String)]);
          break;
        case 'way_segments':
          _waySegments(isDel, r);
          break;
        case 'roundabout_info':
          if (isDel) {
            _run(sq, 'DELETE FROM roundabout_info WHERE way_id = ?', [r[0]]);
            break;
          }
          _run(sq,
              'INSERT OR REPLACE INTO roundabout_info(way_id, junction, entry_edge, exit_edge, exit_number, exit_count) VALUES (?,?,?,?,?,?)',
              [r[0], r[1], _segId(r[2], r[3], r[4]), _segId(r[5], r[6], r[7]), r[8], r[9]]);
          break;
        case 'routing_cells':
          if (isDel) {
            _run(sq, 'DELETE FROM routing_cells WHERE cell_id = ?', [r[0]]);
            break;
          }
          _run(sq,
              'INSERT OR REPLACE INTO routing_cells(cell_id, min_lon, min_lat, max_lon, max_lat, node_count, edge_count) VALUES (?,?,?,?,?,?,?)',
              r);
          break;
        case 'turn_restrictions':
          if (isDel) {
            _run(sq, 'DELETE FROM turn_restrictions WHERE id = ?', [r[0]]);
            break;
          }
          _run(sq,
              'INSERT OR REPLACE INTO turn_restrictions(id, restriction, from_json, via_json, to_json) VALUES (?,?,?,?,?)',
              r);
          break;
        case 'turn_restriction_lookup':
          if (isDel) {
            _run(sq,
                'DELETE FROM turn_restriction_lookup WHERE restriction_id = ? AND from_way = ? AND via_node = ? AND to_way = ?',
                [r[0], r[1], r[2], r[3]]);
            break;
          }
          _run(sq,
              'INSERT OR REPLACE INTO turn_restriction_lookup(restriction_id, from_way, via_node, to_way, restriction) VALUES (?,?,?,?,?)',
              r);
          break;
        case 'mbtiles_metadata':
          if (isDel) {
            _run(mb, 'DELETE FROM metadata WHERE name = ?', [r[0]]);
          } else {
            _run(mb, 'INSERT OR REPLACE INTO metadata(name, value) VALUES (?,?)', r);
          }
          break;
        case 'tiles':
          if (isDel) {
            _run(mb,
                'DELETE FROM map WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?',
                [r[0], r[1], r[2]]);
            break;
          }
          _run(mb, 'INSERT INTO images(tile_data) VALUES (?)',
              [base64Decode(r[3] as String)]);
          final tid = mb.lastInsertRowId;
          _run(mb,
              'INSERT OR REPLACE INTO map(zoom_level, tile_column, tile_row, tile_id) VALUES (?,?,?,?)',
              [r[0], r[1], r[2], tid]);
          break;
        default:
          throw AbmLogicalPatchException('بخش ناشناختهٔ patch: $table');
      }
    }
  }

  void _waySegments(bool isDel, List<dynamic> r) {
    hierarchy = true;
    if (!segIndex) {
      sq.execute('CREATE INDEX IF NOT EXISTS ix_apply_seg_way ON segments(way_id)');
      segIndex = true;
    }
    for (final old in _all(sq, 'SELECT id FROM segments WHERE way_id = ?', [r[0]])) {
      _run(sq, 'DELETE FROM road_index WHERE id = ?', [old[0]]);
    }
    _run(sq, 'DELETE FROM segments WHERE way_id = ?', [r[0]]);
    if (isDel) return;
    final segs = r[1] as List<dynamic>;
    final pieces = r[2] as List<dynamic>;
    final ids = <int>[];
    for (final s in segs) {
      final sg = s as List<dynamic>;
      _run(sq,
          'INSERT INTO segments(a, b, dist_dm, way_id, cell_id) VALUES (?,?,?,?,?)',
          [sg[0], sg[1], sg[2], r[0], sg[3]]);
      final id = sq.lastInsertRowId;
      // road_index ranges (seg_from..seg_to) need contiguous ids within a way
      if (ids.isNotEmpty && id != ids.last + 1) {
        throw const AbmLogicalPatchException('شناسه‌های segment پیوسته نیستند.');
      }
      ids.add(id);
    }
    for (final pc in pieces) {
      final q = pc as List<dynamic>;
      final from = ids[q[0] as int];
      final to = ids[q[1] as int];
      _run(sq,
          'INSERT INTO road_index(id, min_lon, max_lon, min_lat, max_lat, seg_from, seg_to) VALUES (?,?,?,?,?,?,?)',
          [from, q[2], q[3], q[4], q[5], from, to]);
    }
  }

  void finish() {
    if (hierarchy) {
      sq.execute('DELETE FROM hierarchy_edges');
      sq.execute(_hierarchySql);
    }
    sq.execute('DROP INDEX IF EXISTS ix_apply_names');
    if (segIndex) sq.execute('DROP INDEX IF EXISTS ix_apply_seg_way');
    mb.execute(
        'DELETE FROM images WHERE tile_id NOT IN (SELECT tile_id FROM map)');
  }

  void dispose() {
    for (final s in _sqStmts.values) {
      s.dispose();
    }
    for (final s in _mbStmts.values) {
      s.dispose();
    }
    _sqStmts.clear();
    _mbStmts.clear();
  }
}

Future<void> _applySync(
  String basePath,
  String patchPath,
  Map<String, String> m,
  String outPath,
) async {
  final work = Directory('$outPath.work');
  if (await work.exists()) await work.delete(recursive: true);
  await work.create(recursive: true);
  try {
    final sqliteName = m['sqlite']!;
    final mbName = m['mbtiles']!;
    _extractMembers(basePath, work.path, {sqliteName, mbName});
    final sqPath = p.join(work.path, sqliteName);
    final mbPath = p.join(work.path, mbName);

    final sq = sqlite.sqlite3.open(sqPath);
    final mb = sqlite.sqlite3.open(mbPath);
    String? metadataJson;
    String? manifestJson;
    try {
      for (final db in [sq, mb]) {
        db.execute('PRAGMA journal_mode = OFF');
        db.execute('PRAGMA synchronous = OFF');
        db.execute('BEGIN');
      }
      final applier = _Applier(sq, mb);
      var sawHeader = false;
      var sawEnd = false;
      try {
        final lines = File(patchPath)
            .openRead()
            .transform(gzip.decoder)
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        await for (final line in lines) {
          if (line.isEmpty) continue;
          final msg = jsonDecode(line) as Map<String, dynamic>;
          switch (msg['k']) {
            case 'hdr':
              if (msg['spec'] != _kLogicalSpec) {
                throw const AbmLogicalPatchException('نسخهٔ patch منطقی پشتیبانی نمی‌شود.');
              }
              sawHeader = true;
              break;
            case 'members':
              metadataJson = msg['metadata_json'] as String?;
              manifestJson = msg['manifest_json'] as String?;
              break;
            case 'put':
            case 'del':
              if (!sawHeader) {
                throw const AbmLogicalPatchException('patch فاقد سرآیند است.');
              }
              applier.rows(msg['t'] as String, msg['k'] as String,
                  msg['rows'] as List<dynamic>);
              break;
            case 'end':
              sawEnd = true;
              break;
          }
          if (sawEnd) break;
        }
        if (!sawEnd || metadataJson == null || metadataJson!.isEmpty) {
          throw const AbmLogicalPatchException('فایل patch ناقص است.');
        }
        applier.finish();
      } finally {
        applier.dispose();
      }
      sq.execute('COMMIT');
      mb.execute('COMMIT');
      if (_contentDigest(sq, mb) != m['digest']) {
        throw const AbmLogicalPatchException(
            'نتیجهٔ patch با نسخهٔ هدف یکسان نیست.');
      }
    } finally {
      sq.dispose();
      mb.dispose();
    }

    final tmpOut = File('$outPath.zip.tmp');
    if (await tmpOut.exists()) await tmpOut.delete();
    final zip = _ZipWriter(tmpOut.path);
    try {
      zip.addFile(mbName, mbPath, deflate: false);
      zip.addFile(sqliteName, sqPath, deflate: true);
      if (manifestJson != null && manifestJson!.isNotEmpty) {
        zip.addBytes('manifest.json', utf8.encode(manifestJson!));
      }
      zip.addBytes('metadata.json', utf8.encode(metadataJson!));
      zip.close();
    } catch (_) {
      zip.abort();
      if (await tmpOut.exists()) await tmpOut.delete();
      rethrow;
    }
    final out = File(outPath);
    if (await out.exists()) await out.delete();
    await tmpOut.rename(outPath);
  } finally {
    if (await work.exists()) await work.delete(recursive: true);
  }
}

void _extractMembers(String archivePath, String outDir, Set<String> wanted) {
  final input = InputFileStream(archivePath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final found = <String>{};
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (!wanted.contains(name)) continue;
      final output = OutputFileStream(p.join(outDir, name));
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      found.add(name);
    }
    if (found.length != wanted.length) {
      throw const AbmLogicalPatchException('نسخهٔ نصب‌شده ناقص است.');
    }
  } finally {
    input.closeSync();
  }
}

// ----------------------------------------------------------------- zip writer
// Minimal streaming ZIP writer (STORE / raw DEFLATE via dart:io zlib), so the
// rebuilt container never needs the whole sqlite in memory.
final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    t[n] = c;
  }
  return t;
}();

int _crc32(List<int> data, int start, int end, int crc) {
  var c = crc ^ 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ data[i]) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

class _FnSink implements Sink<List<int>> {
  _FnSink(this._onData);
  final void Function(List<int>) _onData;
  @override
  void add(List<int> data) => _onData(data);
  @override
  void close() {}
}

class _ZipEntry {
  _ZipEntry(this.name, this.method, this.crc, this.csize, this.usize, this.offset);
  final String name;
  final int method;
  final int crc;
  final int csize;
  final int usize;
  final int offset;
}

class _ZipWriter {
  _ZipWriter(String path) : _raf = File(path).openSync(mode: FileMode.write);

  static const int _dosDate = ((2020 - 1980) << 9) | (1 << 5) | 1; // 2020-01-01
  static const int _max32 = 0xFFFFFFFF;

  final RandomAccessFile _raf;
  final List<_ZipEntry> _entries = [];
  bool _closed = false;

  void _localHeader(String name, int method, int crc, int csize, int usize) {
    final nameBytes = utf8.encode(name);
    final bd = ByteData(30);
    bd.setUint32(0, 0x04034b50, Endian.little);
    bd.setUint16(4, 20, Endian.little);
    bd.setUint16(6, 0x0800, Endian.little); // UTF-8 names
    bd.setUint16(8, method, Endian.little);
    bd.setUint16(10, 0, Endian.little);
    bd.setUint16(12, _dosDate, Endian.little);
    bd.setUint32(14, crc, Endian.little);
    bd.setUint32(18, csize, Endian.little);
    bd.setUint32(22, usize, Endian.little);
    bd.setUint16(26, nameBytes.length, Endian.little);
    bd.setUint16(28, 0, Endian.little);
    _raf.writeFromSync(bd.buffer.asUint8List());
    _raf.writeFromSync(nameBytes);
  }

  void addBytes(String name, List<int> data) {
    if (data.length >= _max32) {
      throw const AbmLogicalPatchException('ZIP64 پشتیبانی نمی‌شود.');
    }
    final offset = _raf.positionSync();
    final crc = _crc32(data, 0, data.length, 0);
    _localHeader(name, 0, crc, data.length, data.length);
    _raf.writeFromSync(data);
    _entries.add(_ZipEntry(name, 0, crc, data.length, data.length, offset));
  }

  void addFile(String name, String path, {required bool deflate}) {
    final src = File(path).openSync();
    try {
      final usize = src.lengthSync();
      final offset = _raf.positionSync();
      if (usize >= _max32 || offset >= _max32) {
        throw const AbmLogicalPatchException('ZIP64 پشتیبانی نمی‌شود.');
      }
      final method = deflate ? 8 : 0;
      _localHeader(name, method, 0, 0, usize);
      var csize = 0;
      var crc = 0;
      ByteConversionSink? conv;
      if (deflate) {
        conv = ZLibCodec(level: 6, raw: true).encoder.startChunkedConversion(
          _FnSink((chunk) {
            _raf.writeFromSync(chunk);
            csize += chunk.length;
          }),
        );
      }
      final buf = Uint8List(1 << 20);
      while (true) {
        final n = src.readIntoSync(buf);
        if (n <= 0) break;
        crc = _crc32(buf, 0, n, crc);
        if (conv != null) {
          conv.add(Uint8List.fromList(Uint8List.sublistView(buf, 0, n)));
        } else {
          _raf.writeFromSync(buf, 0, n);
          csize += n;
        }
      }
      conv?.close();
      if (csize >= _max32) {
        throw const AbmLogicalPatchException('ZIP64 پشتیبانی نمی‌شود.');
      }
      final end = _raf.positionSync();
      _raf.setPositionSync(offset + 14);
      final bd = ByteData(12)
        ..setUint32(0, crc, Endian.little)
        ..setUint32(4, csize, Endian.little)
        ..setUint32(8, usize, Endian.little);
      _raf.writeFromSync(bd.buffer.asUint8List());
      _raf.setPositionSync(end);
      _entries.add(_ZipEntry(name, method, crc, csize, usize, offset));
    } finally {
      src.closeSync();
    }
  }

  void close() {
    final cdStart = _raf.positionSync();
    for (final e in _entries) {
      final nameBytes = utf8.encode(e.name);
      final bd = ByteData(46);
      bd.setUint32(0, 0x02014b50, Endian.little);
      bd.setUint16(4, (3 << 8) | 20, Endian.little); // unix, 2.0
      bd.setUint16(6, 20, Endian.little);
      bd.setUint16(8, 0x0800, Endian.little);
      bd.setUint16(10, e.method, Endian.little);
      bd.setUint16(12, 0, Endian.little);
      bd.setUint16(14, _dosDate, Endian.little);
      bd.setUint32(16, e.crc, Endian.little);
      bd.setUint32(20, e.csize, Endian.little);
      bd.setUint32(24, e.usize, Endian.little);
      bd.setUint16(28, nameBytes.length, Endian.little);
      bd.setUint16(30, 0, Endian.little);
      bd.setUint16(32, 0, Endian.little);
      bd.setUint16(34, 0, Endian.little);
      bd.setUint16(36, 0, Endian.little);
      bd.setUint32(38, 0x81A40000, Endian.little); // 0644 << 16 | regular file
      bd.setUint32(42, e.offset, Endian.little);
      _raf.writeFromSync(bd.buffer.asUint8List());
      _raf.writeFromSync(nameBytes);
    }
    final cdSize = _raf.positionSync() - cdStart;
    final bd = ByteData(22);
    bd.setUint32(0, 0x06054b50, Endian.little);
    bd.setUint16(4, 0, Endian.little);
    bd.setUint16(6, 0, Endian.little);
    bd.setUint16(8, _entries.length, Endian.little);
    bd.setUint16(10, _entries.length, Endian.little);
    bd.setUint32(12, cdSize, Endian.little);
    bd.setUint32(16, cdStart, Endian.little);
    bd.setUint16(20, 0, Endian.little);
    _raf.writeFromSync(bd.buffer.asUint8List());
    _raf.flushSync();
    _raf.closeSync();
    _closed = true;
  }

  void abort() {
    if (_closed) return;
    try {
      _raf.closeSync();
    } catch (_) {}
    _closed = true;
  }
}
