import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/network/resumable_file_downloader.dart';

/// آدرس پایه‌ی انتشار نقشه‌های ABTINMAP (ریپوی abtin-maps).
const String kAbmReleaseBase = String.fromEnvironment(
  'ABTIN_MAP_BASE',
  defaultValue:
      'https://github.com/abtin123/abtin-maps/releases/download/maps-v4',
);

const String kAbmManifestUrl = '$kAbmReleaseBase/manifest.json';

class AbmFormatException implements Exception {
  const AbmFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// یک فایل قابل دانلود از ریلیز گیت‌هاب: یا کل نقشهٔ یک کشور (تک‌فایلی)
/// یا یکی از پارت‌های یک نقشهٔ چندپارتی (`XX.abm.part0`, `XX.abm.part1`, ...).
///
/// از آنجا که هر آبجکت ریلیزِ گیت‌هاب حداکثر ۲ گیگابایت است، مانیفست برای
/// کشورهای بزرگ‌تر (مثل کانادا، آلمان، فرانسه، روسیه) به‌جای یک فایل، چند
/// پارت منتشر می‌کند که باید به ترتیب دانلود و به هم چسبانده شوند.
class AbmFilePart {
  const AbmFilePart({required this.name, this.size = 0, this.sha256 = ''});

  final String name;
  final int size;

  /// هش SHA-256 این پارت (برای اعتبارسنجی پس از دانلود). ممکن است خالی باشد.
  final String sha256;

  factory AbmFilePart.fromJson(Map<String, dynamic> json) => AbmFilePart(
        name: json['name'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        sha256: (json['sha256'] as String?) ?? '',
      );
}

/// ارجاع مانیفست به patch باینریِ افزایشی میان یک نسخهٔ مشخص و نسخهٔ جدید.
/// patch تنها زمانی معتبر است که هش ABM نصب‌شده با [baseSha256] برابر باشد.
class AbmMapPatch {
  const AbmMapPatch({
    required this.baseSha256,
    required this.manifestFile,
    required this.binFile,
    required this.size,
    required this.sha256,
  });

  final String baseSha256;
  final String manifestFile;
  final String binFile;
  final int size;
  final String sha256;

  factory AbmMapPatch.fromJson(Map<String, dynamic> json) => AbmMapPatch(
        baseSha256: (json['base_sha256'] as String?) ?? '',
        manifestFile: (json['manifest_file'] as String?) ?? '',
        binFile: (json['bin_file'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        sha256: (json['sha256'] as String?) ?? '',
      );

  bool get isUsable =>
      baseSha256.isNotEmpty && manifestFile.isNotEmpty && binFile.isNotEmpty;
}

class AbmDownloadCancelled implements Exception {
  const AbmDownloadCancelled();
  @override
  String toString() => 'دانلود توسط کاربر متوقف شد.';
}

class AbmDownloadProgress {
  const AbmDownloadProgress(this.received, this.total);
  final int received;
  final int? total;
  double? get fraction =>
      (total == null || total == 0) ? null : received / total!;
}

/// دانلود، کش و باز کردن فایل‌های .abm به‌صورت کاملاً آفلاین‌محور:
/// یک‌بار دانلود، سپس همه‌ی مسیریابی/رندر از فایل لوکال خوانده می‌شود.
class AbmMapService {
  AbmMapService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  Directory? _dir;

  Future<Directory> _mapsDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'abtinmap'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<File> localFile(String name) async =>
      File(p.join((await _mapsDir()).path, name));

  Future<File> _versionFile(String name) async =>
      File(p.join((await _mapsDir()).path, '$name.version'));

  Future<void> _activatePending(File pending, File target) async {
    if (!await pending.exists() || await pending.length() == 0) {
      throw const AbmFormatException('فایل موقت نقشه وجود ندارد یا خالی است.');
    }
    await Isolate.run(() => _validateAbmContainer(pending.path));
    // Both paths are in the maps directory (same filesystem). POSIX rename
    // replaces the directory entry atomically; never delete the installed map
    // first, because a crash between delete and rename would lose the old map.
    await pending.rename(target.path);
  }

  Future<void> _writeVersion(String name, String version) async {
    final file = await _versionFile(name);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(version, flush: true);
    await pending.rename(file.path);
  }

  static void _validateAbmContainer(String path) {
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final names = <String>{};
      Map<String, dynamic>? metadata;
      Map<String, dynamic>? manifest;
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final normalized = entry.name.replaceAll('\\', '/');
        if (normalized.split('/').length != 1) continue;
        names.add(normalized);
        if (normalized == 'metadata.json') {
          metadata = jsonDecode(utf8.decode(entry.readBytes()!)) as Map<String, dynamic>;
        } else if (normalized == 'manifest.json') {
          manifest = jsonDecode(utf8.decode(entry.readBytes()!)) as Map<String, dynamic>;
        }
      }
      if (metadata == null) {
        throw const AbmFormatException('بستهٔ ABM فاقد metadata.json است.');
      }
      final database = (manifest?['database'] as String?) ?? (metadata!['database'] as String?) ?? '';
      final tiles = (manifest?['tiles'] as String?) ?? (metadata!['tile_file'] as String?) ?? '';
      if (manifest != null) {
        final manifestId = (manifest!['id'] as String?)?.trim();
        if (manifestId != null && manifestId.isNotEmpty && metadata!['id'] != null &&
            '${metadata!['id']}' != manifestId) {
          throw const AbmFormatException('شناسهٔ Manifest و metadata یکسان نیست.');
        }
        if (manifest!['format'] != null && manifest!['format'] != 'ABM') {
          throw const AbmFormatException('Manifest داخلی ABM نامعتبر است.');
        }
      }
      final safeMember = (String n, String ext) =>
          n.isNotEmpty && n == p.basename(n) && n.toLowerCase().endsWith(ext);
      // New format: the runtime store names are derived from the province id.
      // Legacy format: map.sqlite/map.mbtiles remain accepted for migration.
      if (!safeMember(database, '.sqlite') || !safeMember(tiles, '.mbtiles')) {
        throw const AbmFormatException('نام فایل‌های SQLite/MBTiles در metadata معتبر نیست.');
      }
      if (!names.contains(database) || !names.contains(tiles)) {
        throw AbmFormatException(
          'بستهٔ ABM ناقص است: database=$database tiles=$tiles',
        );
      }
      final sqliteCount = names.where((n) => n.toLowerCase().endsWith('.sqlite')).length;
      final mbtilesCount = names.where((n) => n.toLowerCase().endsWith('.mbtiles')).length;
      if (sqliteCount != 1 || mbtilesCount != 1) {
        throw const AbmFormatException('بستهٔ ABM باید دقیقاً یک SQLite و یک MBTiles داشته باشد.');
      }
      if (metadata!['format'] != 'ABM') {
        throw const AbmFormatException('فرمت بستهٔ ABM پشتیبانی نمی‌شود.');
      }
      final version = (metadata!['version'] as num?)?.toInt() ?? 0;
      if (version < 6) {
        throw AbmFormatException('نسخه ABM پشتیبانی نمی‌شود: $version (Builder v3 requires ABM v6+)');
      }
      if (version >= 7 && manifest == null) {
        throw const AbmFormatException('ABM v7 فاقد manifest.json داخلی است.');
      }
      if (metadata!['tiles'] != true || metadata!['tile_format'] != 'pbf') {
        throw const AbmFormatException('Metadata بستهٔ ABM با قرارداد MBTiles سازندهٔ جدید سازگار نیست.');
      }
      final id = (metadata!['id'] as String?)?.trim();
      if (id != null && id.isNotEmpty) {
        final expectedDb = '$id.sqlite';
        final expectedTiles = '$id.mbtiles';
        // New packages must be self-identifying. Legacy packages are accepted
        // only when metadata explicitly points to the legacy names.
        if (database != expectedDb || tiles != expectedTiles) {
          if (database != 'map.sqlite' || tiles != 'map.mbtiles') {
            throw const AbmFormatException('نام فایل‌های ABM با شناسهٔ بسته سازگار نیست.');
          }
        }
      }
    } on AbmFormatException {
      rethrow;
    } catch (error) {
      throw AbmFormatException('فایل ABM یا metadata آن معتبر نیست: $error');
    } finally {
      input.closeSync();
    }
  }

  Future<bool> isInstalled(String name) async =>
      (await localFile(name)).exists();

  Future<String?> installedVersion(String name) async {
    final f = await _versionFile(name);
    if (await f.exists()) {
      final value = (await f.readAsString()).trim();
      if (value.isNotEmpty && value != 'unknown') return value;
    }
    // Old installations may have the ABM but no sidecar version (or an
    // 'unknown' sidecar). The file itself is the source of truth, so compute
    // its SHA-256 once and persist it. This makes weekly release updates
    // visible immediately even after an app upgrade/restore.
    final target = await localFile(name);
    if (!await target.exists()) return null;
    final digest = await _sha256(target);
    await f.writeAsString(digest, flush: true);
    return digest;
  }

  Future<String?> installedSha256(String name) async {
    final target = await localFile(name);
    if (!await target.exists()) return null;
    return _sha256(target);
  }

  /// دانلود (یا به‌روزرسانی) نقشه. اگر فایل موجود و هم‌نسخه باشد کاری نمی‌کند.
  Future<File> download(
    String name, {
    String? url,
    String? version,
    bool force = false,
    void Function(AbmDownloadProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final target = await localFile(name);
    
    if (!force && await target.exists()) {
      if (version == null || (await installedVersion(name)) == version) {
        
        return target;
      }
    }

    final uri = Uri.parse(url ?? '$kAbmReleaseBase/$name');
    final dir = await _mapsDir();
    final pending = File(p.join(dir.path, '.staging', name, 'download'));
    final downloader = ResumableFileDownloader(
      userAgent: 'AbtinMaps/1.0 (ir.abtin.abtin_maps)',
    );
    try {
      await downloader.download(
        sources: [uri],
        destination: pending,
        onProgress: (progress) {
          if (isCancelled?.call() ?? false) {
            downloader.cancel();
            return;
          }
          onProgress?.call(AbmDownloadProgress(
            progress.receivedBytes,
            progress.totalBytes,
          ));
        },
      );
    } on FileDownloadCancelled {
      throw const AbmDownloadCancelled();
    } on FileDownloadException catch (error) {
      throw AbmFormatException(error.message);
    }
    if (isCancelled?.call() ?? false) throw const AbmDownloadCancelled();
    if (version != null && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(version) &&
        !await _matchesSha256(pending, version)) {
      throw const AbmFormatException('هش فایل نقشه معتبر نیست.');
    }
    await _activatePending(pending, target);
    await _writeVersion(name, version ?? 'unknown');
    return target;
  }

  /// نصب یک ABM کوچکِ همراه APK برای آزمون end-to-end. مسیر همان نصب شبکه‌ای
  /// است: ابتدا فایل موقت نوشته، checksum بررسی و سپس اتمیک جایگزین می‌شود.
  /// بنابراین بستهٔ آزمایشی renderer یا راه میان‌برِ جدا نمی‌سازد.
  Future<File> installBundledAsset({
    required String name,
    required String assetPath,
    required String version,
    void Function(AbmDownloadProgress)? onProgress,
  }) async {
    final target = await localFile(name);
    if (await target.exists() &&
        (version.isEmpty || (await installedVersion(name)) == version)) {
      return target;
    }
    final data = await rootBundle.load(assetPath);
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final pending = File('${target.path}.part');
    await _deleteIfExists(pending);
    try {
      await pending.writeAsBytes(bytes, flush: true);
      onProgress?.call(AbmDownloadProgress(bytes.length, bytes.length));
      if (version.isNotEmpty && !await _matchesSha256(pending, version)) {
        throw const AbmFormatException('هش بستهٔ نقشهٔ آزمایشی معتبر نیست.');
      }
      await _activatePending(pending, target);
      await _writeVersion(name, version);
      return target;
    } catch (_) {
      await _deleteIfExists(pending);
      rethrow;
    }
  }

  /// دانلود (یا به‌روزرسانی) یک بستهٔ نقشه که ممکن است از چند پارت تشکیل
  /// شده باشد (کشورهای بزرگ که به‌خاطر سقف ۲ گیگابایتیِ آبجکت‌های ریلیز
  /// گیت‌هاب به چند فایل `part0`, `part1`, ... تقسیم شده‌اند).
  ///
  /// هر پارت جداگانه و با قابلیت ادامه‌ی دانلود (Range/Resume) دریافت
  /// می‌شود، در صورت وجود `sha256` اعتبارسنجی می‌شود، و در پایان همهٔ پارت‌ها
  /// به ترتیب به فایل نهاییِ `<id>.abm` چسبانده می‌شوند. اگر پارتی از قبل
  /// روی دیسک باشد و اندازه/هشش درست باشد، دوباره دانلود نمی‌شود — بنابراین
  /// قطع‌شدن اینترنت وسط دانلود یک نقشهٔ چندگیگابایتی، کل کار را از صفر
  /// شروع نمی‌کند.
  /// مجموع بایت‌های نیمه‌دانلودشدهٔ یک نقشه (پارت‌های کامل + فایل‌های `.part`).
  Future<int> stagedBytes({required String id, String version = ''}) async {
    try {
      final dir = await _mapsDir();
      final key = version.isNotEmpty ? version.toLowerCase() : 'unversioned';
      final staging = Directory(p.join(dir.path, '.staging', id, key));
      if (!await staging.exists()) return 0;
      var sum = 0;
      await for (final e in staging.list()) {
        if (e is File) sum += await e.length();
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  Future<File> downloadRegion({
    required String id,
    List<AbmFilePart> files = const [],
    AbmMapPatch? patch,
    String downloadBase = '',
    int totalSizeBytes = 0,
    String expectedSha256 = '',
    bool force = false,
    void Function(AbmDownloadProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final name = '$id.abm';
    final target = await localFile(name);
    
    if (!force && await target.exists()) {
      // The ABM file is the source of truth. The sidecar version is only an
      // optimization and may be missing after an older install/restore.
      final sidecarVersion = await installedVersion(name);
      String? localSha;
      if (expectedSha256.isNotEmpty) {
        localSha = await _matchesSha256(target, expectedSha256)
            ? expectedSha256
            : await _sha256(target);
      } else if (patch?.isUsable == true) {
        // A patch can still be selected when the online manifest omitted the
        // target SHA. In that case we need the actual installed ABM SHA to
        // validate patch.base_sha256.
        localSha = await _sha256(target);
      }
      if (expectedSha256.isEmpty || localSha == expectedSha256) {
        if (expectedSha256.isNotEmpty && sidecarVersion != expectedSha256) {
          await (await _versionFile(name)).writeAsString(expectedSha256);
        }
        
        return target;
      }
      if (patch != null &&
          patch.isUsable &&
          localSha == patch.baseSha256) {
        try {
          return await _downloadAndApplyPatch(
            id: id,
            target: target,
            downloadBase: downloadBase,
            patch: patch,
            expectedSha256: expectedSha256,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
        } on AbmDownloadCancelled {
          rethrow;
        } catch (error) {
          // patch یک بهینه‌سازی است: خطای آن نباید نسخهٔ فعلی را خراب کند و
          // در صورت نیاز دانلود کاملِ معتبر را جایگزین می‌کنیم.
          
        }
      }
    }

    final parts = files.isNotEmpty
        ? files
        : [
            AbmFilePart(
                name: name, size: totalSizeBytes, sha256: expectedSha256)
          ];
    final base = downloadBase.isNotEmpty ? downloadBase : '$kAbmReleaseBase/';
    final total = totalSizeBytes > 0
        ? totalSizeBytes
        : parts.fold<int>(0, (sum, part) => sum + part.size);

    final dir = await _mapsDir();
    if (id.isEmpty || id.contains('/') || id.contains('\\') ||
        id == '.' || id == '..') {
      throw const AbmFormatException('شناسهٔ نقشه نامعتبر است.');
    }
    final versionKey = expectedSha256.isNotEmpty
        ? expectedSha256.toLowerCase()
        : 'unversioned';
    final stagingDir = Directory(p.join(dir.path, '.staging', id, versionKey));
    await stagingDir.create(recursive: true);
    await _pruneStaging(id, keep: versionKey);
    final downloader = ResumableFileDownloader(
      userAgent: 'AbtinMaps/1.0 (ir.abtin.abtin_maps)',
    );
    var bytesBeforePart = 0;
    final partFiles = <File>[];

    for (final part in parts) {
      if (isCancelled?.call() ?? false) throw const AbmDownloadCancelled();
      if (part.name.isEmpty || p.basename(part.name) != part.name ||
          part.name == '.' || part.name == '..') {
        throw const AbmFormatException('نام پارت نقشه نامعتبر است.');
      }
      final partFile = File(p.join(stagingDir.path, part.name));
      if (!await _partIsValid(partFile, part)) {
        final baseForPart = bytesBeforePart;
        try {
          await downloader.download(
            sources: [Uri.parse('$base${part.name}')],
            destination: partFile,
            minimumBytes: part.size > 0 ? part.size : null,
            onProgress: (progress) {
              // چک کردن لغو در هر chunk (نه فقط بین پارت‌ها)؛ وگرنه دکمه‌ی
              // «توقف» تا پایان کامل دانلودِ همان پارت اثری ندارد.
              if (isCancelled?.call() ?? false) {
                downloader.cancel();
                return;
              }
              onProgress?.call(AbmDownloadProgress(
                baseForPart + progress.receivedBytes,
                total > 0 ? total : null,
              ));
            },
          );
        } on FileDownloadCancelled {
          throw const AbmDownloadCancelled();
        } on FileDownloadException catch (error) {
          throw AbmFormatException(error.message);
        }
        if (isCancelled?.call() ?? false) throw const AbmDownloadCancelled();
        if (part.sha256.isNotEmpty) {
          final actual = await _sha256(partFile);
          if (actual != part.sha256.toLowerCase()) {
            // The release is mutable: the cached manifest hash may simply be
            // stale. Keep a finished single-file download under its real hash
            // so a refreshed manifest can adopt it without downloading again.
            if (parts.length == 1) {
              await _keepUnderActualHash(partFile, id, part.name, actual);
            } else {
              await _deleteIfExists(partFile);
            }
            throw AbmFormatException(
                'پارت «${part.name}» ناقص یا خراب دانلود شد؛ دوباره تلاش کنید.');
          }
        }
      }
      else {
        onProgress?.call(AbmDownloadProgress(
          bytesBeforePart + part.size,
          total > 0 ? total : null,
        ));
      }
      bytesBeforePart += part.size;
      partFiles.add(partFile);
    }

    final File finalFile;
    if (partFiles.length == 1) {
      // Single-file map: verify the hash and validate the ABM container while
      // the file is still in staging. It leaves staging (atomic rename inside
      // _activatePending) only after both checks pass, so a failed check can
      // never destroy a multi-gigabyte download that would then start again
      // from zero.
      final staged = partFiles.first;
      final alreadyVerified = expectedSha256.isEmpty ||
          (parts.first.sha256.isNotEmpty &&
              parts.first.sha256.toLowerCase() ==
                  expectedSha256.toLowerCase());
      if (!alreadyVerified) {
        final actual = await _sha256(staged);
        if (actual != expectedSha256.toLowerCase()) {
          await _keepUnderActualHash(staged, id, parts.first.name, actual);
          throw const AbmFormatException(
              'فایل نهایی نقشه نامعتبر است؛ دوباره تلاش کنید.');
        }
      }
      await _activatePending(staged, target);
      finalFile = target;
    } else {
      final tmp = File('${target.path}.part');
      await _deleteIfExists(tmp);
      final sink = tmp.openWrite();
      try {
        for (final partFile in partFiles) {
          await sink.addStream(partFile.openRead());
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (expectedSha256.isNotEmpty &&
          !await _matchesSha256(tmp, expectedSha256)) {
        await _deleteIfExists(tmp);
        throw const AbmFormatException(
            'فایل نهایی نقشه پس از ترکیب پارت‌ها نامعتبر بود؛ دوباره تلاش کنید.');
      }
      await _activatePending(tmp, target);
      finalFile = target;
    }
    
    await _writeVersion(
      name,
      expectedSha256.isNotEmpty ? expectedSha256 : 'unknown',
    );

    // پارت‌های موقت را فقط پس از موفقیتِ کامل پاک می‌کنیم.
    //
    // نکته‌ی مهم: وقتی نقشه فقط یک پارت دارد (یعنی اکثر کشورها — همه‌ی
    // آن‌هایی که به‌خاطر سقف ۲گیگابایتیِ ریلیز گیت‌هاب نیازی به تقسیم ندارند)،
    // نامِ آن پارت دقیقاً همان `<id>.abm` است؛ یعنی `partFile.path` با
    // `target.path` یکی است. پیش از این، این حلقه بدون بررسی، همان فایلِ
    // نهاییِ تازه‌نصب‌شده را هم پاک می‌کرد — نتیجه‌اش این بود که دانلود ظاهراً
    // با موفقیت تمام می‌شد اما بلافاصله فایل نصب‌شده حذف می‌شد، و کاربر با
    // برگشتن به صفحه‌ی دانلود دوباره «نصب‌نشده» می‌دید و مجبور بود از صفر
    // دانلود کند. اینجا صراحتاً از حذفِ فایلی که همان فایل نهایی است
    // جلوگیری می‌شود.
    for (final partFile in partFiles) {
      if (partFile.path == target.path) continue;
      await _deleteIfExists(partFile);
    }
    try {
      final leftovers = Directory(p.join(dir.path, '.staging', id));
      if (await leftovers.exists()) await leftovers.delete(recursive: true);
    } catch (_) {}
    onProgress?.call(AbmDownloadProgress(total, total > 0 ? total : null));
    return target;
  }

  Future<File> _downloadAndApplyPatch({
    required String id,
    required File target,
    required String downloadBase,
    required AbmMapPatch patch,
    required String expectedSha256,
    required void Function(AbmDownloadProgress)? onProgress,
    required bool Function()? isCancelled,
  }) async {
    final base = downloadBase.isNotEmpty ? downloadBase : '$kAbmReleaseBase/';
    final manifestResponse = await _client
        .get(Uri.parse('$base${patch.manifestFile}'))
        .timeout(const Duration(seconds: 20));
    if (manifestResponse.statusCode != HttpStatus.ok) {
      throw const AbmFormatException(
          'دریافت مشخصات به‌روزرسانی نقشه ناموفق بود.');
    }
    final decoded = jsonDecode(utf8.decode(manifestResponse.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const AbmFormatException('مشخصات به‌روزرسانی نقشه نامعتبر است.');
    }
    final manifest = _AbmChunkPatchManifest.fromJson(decoded);
    if (manifest.code != id ||
        manifest.baseSha256 != patch.baseSha256 ||
        (expectedSha256.isNotEmpty &&
            manifest.targetSha256 != expectedSha256) ||
        manifest.targetSize <= 0 ||
        manifest.chunkSize <= 0 ||
        !await _matchesSha256(target, patch.baseSha256)) {
      throw const AbmFormatException(
          'نسخهٔ نصب‌شده با به‌روزرسانی نقشه سازگار نیست.');
    }

    final dir = await _mapsDir();
    final patchFile = File(p.join(dir.path, '$id.update.abmpatch'));
    final downloader = ResumableFileDownloader(
      userAgent: 'AbtinMaps/1.0 (ir.abtin.abtin_maps)',
    );
    try {
      await downloader.download(
        sources: [Uri.parse('$base${patch.binFile}')],
        destination: patchFile,
        minimumBytes: patch.size > 0 ? patch.size : null,
        onProgress: (progress) {
          if (isCancelled?.call() ?? false) {
            downloader.cancel();
            return;
          }
          onProgress?.call(
            AbmDownloadProgress(progress.receivedBytes, progress.totalBytes),
          );
        },
      );
    } on FileDownloadCancelled {
      throw const AbmDownloadCancelled();
    } on FileDownloadException catch (error) {
      throw AbmFormatException(error.message);
    }

    if (isCancelled?.call() ?? false) throw const AbmDownloadCancelled();
    if ((patch.sha256.isNotEmpty &&
            !await _matchesSha256(patchFile, patch.sha256)) ||
        (manifest.patchSha256.isNotEmpty &&
            !await _matchesSha256(patchFile, manifest.patchSha256))) {
      await _deleteIfExists(patchFile);
      throw const AbmFormatException('هش فایل به‌روزرسانی نقشه نادرست است.');
    }

    final pending = await _applyChunkPatch(
      source: target,
      patchFile: patchFile,
      manifest: manifest,
      isCancelled: isCancelled,
    );
    if (expectedSha256.isNotEmpty &&
        !await _matchesSha256(pending, expectedSha256)) {
      await _deleteIfExists(pending);
      throw const AbmFormatException(
          'نسخهٔ ساخته‌شده از به‌روزرسانی نقشه معتبر نیست.');
    }
    await _activatePending(pending, target);
    await _writeVersion(
      '$id.abm',
      expectedSha256.isNotEmpty ? expectedSha256 : manifest.targetSha256,
    );
    await _deleteIfExists(patchFile);
    
    return target;
  }

  Future<File> _applyChunkPatch({
    required File source,
    required File patchFile,
    required _AbmChunkPatchManifest manifest,
    required bool Function()? isCancelled,
  }) async {
    final pending = File('${source.path}.update');
    await _deleteIfExists(pending);
    final sourceReader = await source.open();
    final patchReader = await patchFile.open();
    final output = pending.openWrite();
    try {
      final ops = manifest.ops;
      if (ops != null) {
        const step = 1024 * 1024;
        for (final op in ops) {
          final reader = op.fromBase ? sourceReader : patchReader;
          await reader.setPosition(op.offset);
          var left = op.length;
          while (left > 0) {
            if (isCancelled?.call() ?? false) throw const AbmDownloadCancelled();
            final bytes = await reader.read(left < step ? left : step);
            if (bytes.isEmpty) {
              throw const AbmFormatException(
                  'فایل به‌روزرسانی یا نسخهٔ قبلی نقشه ناقص است.');
            }
            output.add(bytes);
            left -= bytes.length;
          }
        }
        await output.flush();
        return pending;
      }
      final changedBlocks = {
        for (final block in manifest.blocks) block.index: block
      };
      final blockCount =
          (manifest.targetSize + manifest.chunkSize - 1) ~/ manifest.chunkSize;
      for (var index = 0; index < blockCount; index++) {
        if (isCancelled?.call() ?? false) throw const AbmDownloadCancelled();
        final expectedLength = index == blockCount - 1
            ? manifest.targetSize - index * manifest.chunkSize
            : manifest.chunkSize;
        final changed = changedBlocks[index];
        if (changed != null) {
          if (changed.size != expectedLength || changed.offset < 0) {
            throw const AbmFormatException(
                'بلوک به‌روزرسانی نقشه نامعتبر است.');
          }
          await patchReader.setPosition(changed.offset);
          final bytes = await patchReader.read(expectedLength);
          if (bytes.length != expectedLength) {
            throw const AbmFormatException('فایل به‌روزرسانی نقشه ناقص است.');
          }
          output.add(bytes);
        } else {
          await sourceReader.setPosition(index * manifest.chunkSize);
          final bytes = await sourceReader.read(expectedLength);
          if (bytes.length != expectedLength) {
            throw const AbmFormatException(
                'نسخهٔ قبلی نقشه برای به‌روزرسانی معتبر نیست.');
          }
          output.add(bytes);
        }
      }
      await output.flush();
    } catch (_) {
      await _deleteIfExists(pending);
      rethrow;
    } finally {
      await output.close();
      await patchReader.close();
      await sourceReader.close();
    }
    return pending;
  }

  Future<bool> _partIsValid(File file, AbmFilePart part) async {
    if (!await file.exists()) return false;
    if (part.size > 0 && await file.length() != part.size) return false;
    if (part.sha256.isEmpty) return true;
    return _matchesSha256(file, part.sha256);
  }

  Future<bool> _matchesSha256(File file, String expected) async {
    if (expected.isEmpty) return true;
    return (await _sha256(file)).toLowerCase() == expected.toLowerCase();
  }

  Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase();
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }

  /// Moves a finished-but-mismatching download to `.staging/<id>/<actual sha>/`.
  /// If a refreshed manifest turns out to list exactly that hash, the next
  /// call finds a valid part there and installs it with no network transfer.
  Future<void> _keepUnderActualHash(
    File file,
    String id,
    String partName,
    String actualSha,
  ) async {
    try {
      final dir = await _mapsDir();
      final keep = File(
          p.join(dir.path, '.staging', id, actualSha.toLowerCase(), partName));
      if (keep.path == file.path) return;
      await keep.parent.create(recursive: true);
      await _deleteIfExists(keep);
      await file.rename(keep.path);
    } catch (_) {
      await _deleteIfExists(file);
    }
  }

  /// Removes staging folders of other versions of this map (they can never be
  /// resumed and just hold gigabytes of disk).
  Future<void> _pruneStaging(String id, {required String keep}) async {
    try {
      final dir = await _mapsDir();
      final root = Directory(p.join(dir.path, '.staging', id));
      if (!await root.exists()) return;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory && p.basename(entity.path) == keep) continue;
        await entity.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> deleteMap(String name) async {
    final f = await localFile(name);
    if (await f.exists()) await f.delete();
    final v = await _versionFile(name);
    if (await v.exists()) await v.delete();
  }

  /// بستن کلاینت شبکه هنگام dispose شدن provider؛ فایل‌های ABM فقط در زمان خواندن باز می‌مانند.
  void closeMap() {
    _client.close();
  }

  Future<List<String>> installedMaps() async {
    final dir = await _mapsDir();
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .where((n) => n.toLowerCase().endsWith('.abm'))
        .toList();
  }
}

class _AbmChunkPatchManifest {
  const _AbmChunkPatchManifest({
    required this.code,
    required this.baseSha256,
    required this.targetSha256,
    required this.targetSize,
    required this.chunkSize,
    required this.patchSha256,
    required this.blocks,
    this.ops,
  });

  final String code;
  final String baseSha256;
  final String targetSha256;
  final int targetSize;
  final int chunkSize;
  final String patchSha256;
  final List<_AbmChunkPatchBlock> blocks;

  /// Schema /2: ordered copy-from-base / take-from-patch operations that
  /// rebuild the target file even when member offsets shifted. Null for /1.
  final List<_AbmPatchOp>? ops;

  factory _AbmChunkPatchManifest.fromJson(Map<String, dynamic> json) {
    final schema = json['schema'];
    if (schema != 'ABTINMAP-CHUNK-PATCH/1' &&
        schema != 'ABTINMAP-CHUNK-PATCH/2') {
      throw const AbmFormatException('نسخهٔ patch نقشه پشتیبانی نمی‌شود.');
    }
    List<_AbmPatchOp>? ops;
    if (schema == 'ABTINMAP-CHUNK-PATCH/2') {
      ops = (json['ops'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(_AbmPatchOp.fromJson)
          .toList();
      final total = ops.fold<int>(0, (sum, op) => sum + op.length);
      if (ops.isEmpty ||
          ops.any((op) => !op.isValid) ||
          total != ((json['target_size'] as num?)?.toInt() ?? -1)) {
        throw const AbmFormatException('عملیات patch نقشه نامعتبر است.');
      }
    }
    final blocks = (json['blocks'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_AbmChunkPatchBlock.fromJson)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (blocks.map((block) => block.index).toSet().length != blocks.length ||
        blocks.any((block) => block.index < 0 || block.size <= 0)) {
      throw const AbmFormatException('بلوک‌های patch نقشه نامعتبر هستند.');
    }
    return _AbmChunkPatchManifest(
      code: (json['code'] as String?) ?? '',
      baseSha256: (json['base_sha256'] as String?) ?? '',
      targetSha256: (json['target_sha256'] as String?) ?? '',
      targetSize: (json['target_size'] as num?)?.toInt() ?? 0,
      chunkSize: (json['chunk_size'] as num?)?.toInt() ?? 0,
      patchSha256: (json['patch_sha256'] as String?) ?? '',
      blocks: blocks,
      ops: ops,
    );
  }
}

class _AbmChunkPatchBlock {
  const _AbmChunkPatchBlock({
    required this.index,
    required this.offset,
    required this.size,
  });

  final int index;
  final int offset;
  final int size;

  factory _AbmChunkPatchBlock.fromJson(Map<String, dynamic> json) =>
      _AbmChunkPatchBlock(
        index: (json['index'] as num?)?.toInt() ?? -1,
        offset: (json['offset'] as num?)?.toInt() ?? -1,
        size: (json['size'] as num?)?.toInt() ?? -1,
      );
}

class _AbmPatchOp {
  const _AbmPatchOp({
    required this.fromBase,
    required this.offset,
    required this.length,
  });

  final bool fromBase;
  final int offset;
  final int length;

  bool get isValid => offset >= 0 && length > 0;

  factory _AbmPatchOp.fromJson(Map<String, dynamic> json) {
    final src = json['src'];
    if (src != 'base' && src != 'patch') {
      return const _AbmPatchOp(fromBase: false, offset: -1, length: -1);
    }
    return _AbmPatchOp(
      fromBase: src == 'base',
      offset: (json['offset'] as num?)?.toInt() ?? -1,
      length: (json['len'] as num?)?.toInt() ?? -1,
    );
  }
}
