import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// مخزن گیت‌هابی که APK نسخه‌های جدید در Releases آن منتشر می‌شود.
/// فرمت: `owner/repo`. اگر APK در مخزن دیگری منتشر می‌شود فقط همین را عوض کنید.
const String kAppUpdateRepo = 'abtin123/Project';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.apkUrl,
    required this.releasePageUrl,
    required this.notes,
    required this.apkSizeBytes,
  });

  final String currentVersion;
  final String latestVersion;
  final String? apkUrl;
  final String releasePageUrl;
  final String notes;
  final int apkSizeBytes;

  /// لینکی که کاربر باید باز کند: خودِ APK، و اگر نبود صفحهٔ release.
  String get downloadUrl => apkUrl ?? releasePageUrl;
}

class AppUpdateService {
  AppUpdateService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static bool _isApkAsset(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.apk') || n.endsWith('.apk.zip');
  }

  static final RegExp _versionRe = RegExp(r'(\d+)\.(\d+)\.(\d+)');

  static List<int>? parseVersion(String text) {
    final m = _versionRe.firstMatch(text);
    if (m == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
  }

  static int compare(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
  }

  /// null یعنی نسخهٔ جدیدتری وجود ندارد (یا بررسی ممکن نشد).
  Future<AppUpdateInfo?> check() async {
    final info = await PackageInfo.fromPlatform();
    final current = parseVersion(info.version);
    if (current == null) return null;

    final response = await _client
        .get(
          Uri.parse(
              'https://api.github.com/repos/$kAppUpdateRepo/releases?per_page=30'),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body);
    if (data is! List) return null;

    // مخزن ممکن است release نقشه‌ها (مثل maps-v4) را هم داشته باشد؛ فقط
    // releaseهایی که فایل .apk دارند و شمارهٔ نسخه در tag آن‌هاست حساب می‌شوند.
    List<int>? bestVersion;
    Map<String, dynamic>? best;
    Map<String, dynamic>? bestApk;
    for (final item in data) {
      if (item is! Map<String, dynamic>) continue;
      if (item['draft'] == true || item['prerelease'] == true) continue;
      final version = parseVersion('${item['tag_name'] ?? ''}');
      if (version == null) continue;
      final assets = (item['assets'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .where((a) => _isApkAsset('${a['name']}'))
          .toList();
      if (assets.isEmpty) continue;
      if (bestVersion == null || compare(version, bestVersion) > 0) {
        bestVersion = version;
        best = item;
        // اگر چند APK بود، نسخهٔ universal/release ترجیح دارد.
        // فایل خام .apk بر .apk.zip ترجیح دارد (release منتشرشده فعلاً
        // به‌صورت abtin_maps-V0.0.13.apk.zip است).
        final plain = assets
            .where((a) => '${a['name']}'.toLowerCase().endsWith('.apk'))
            .toList();
        final pool = plain.isNotEmpty ? plain : assets;
        bestApk = pool.firstWhere(
          (a) => '${a['name']}'.toLowerCase().contains('release'),
          orElse: () => pool.first,
        );
      }
    }
    if (best == null || bestVersion == null || bestApk == null) return null;
    if (compare(bestVersion, current) <= 0) return null;

    return AppUpdateInfo(
      currentVersion: info.version,
      latestVersion: bestVersion.join('.'),
      apkUrl: '${bestApk['name'] ?? ''}'.toLowerCase().endsWith('.apk')
          ? bestApk['browser_download_url'] as String?
          : null,
      releasePageUrl: '${best['html_url'] ?? 'https://github.com/$kAppUpdateRepo/releases'}',
      notes: '${best['body'] ?? ''}'.trim(),
      apkSizeBytes: (bestApk['size'] as num?)?.toInt() ?? 0,
    );
  }
}

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  return AppUpdateService();
});

/// یک‌بار در هر اجرای برنامه بررسی می‌شود؛ خطای شبکه/فیلتر بی‌صدا نادیده
/// گرفته می‌شود تا هیچ‌وقت مزاحم ناوبری نشود.
final appUpdateProvider = FutureProvider<AppUpdateInfo?>((ref) async {
  try {
    return await ref.read(appUpdateServiceProvider).check();
  } catch (_) {
    return null;
  }
});

/// نسخهٔ نصب‌شده برای نمایش در صفحهٔ «درباره».
final installedVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
});

/// کاربر در همین اجرا «بعداً» را زده؛ دوباره پنجره نشان داده نشود.
final appUpdateDismissedProvider = StateProvider<bool>((ref) => false);
