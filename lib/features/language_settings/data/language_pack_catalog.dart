library;

import '../../../core/localization/locale_flags.dart';
import '../../../core/localization/app_localizations.dart';

/// Remote ABL packs provide every locale except Persian and English, which
/// are the only locales bundled in the APK.
const String kLangPacksBaseUrl =
    'https://github.com/abtin123/Make-langueg/releases/download/langpacks-latest';
const String kLangPacksManifestUrl = '$kLangPacksBaseUrl/manifest.json';

/// لینک استاندارد دانلود هر بسته: `<base>/lang_<code>.abl`.
String langPackUrlFor(String code) => '$kLangPacksBaseUrl/lang_$code.abl';

class LanguagePack {
  const LanguagePack({
    required this.code,
    required this.name,
    required this.flag,
    required this.downloadUrl,
    this.fallbackUrl = '',
    this.direction = 'ltr',
    this.stringCount = 0,
    this.sizeBytes = 0,
    this.sha256 = '',
    this.version = '',
  });

  final String code;
  final String name;
  final String flag;
  final String downloadUrl;

  /// لینکِ ذکرشده در manifest؛ فقط اگر لینک استاندارد جواب نداد امتحان می‌شود.
  final String fallbackUrl;
  final String direction;
  final int stringCount;
  final int sizeBytes;
  final String sha256;
  final String version;

  String get localFileName => 'lang_$code.abl';

  factory LanguagePack.fromManifestJson(Map<String, dynamic> json) {
    final rawCode = json['language_code'] ?? json['code'] ?? json['locale'];
    if (rawCode is! String || rawCode.trim().isEmpty) {
      throw const FormatException('رکورد زبان کد معتبر ندارد.');
    }
    final code = rawCode.trim().toLowerCase();
    final rawName = json['language'] ?? json['name'] ?? json['language_name'];
    final rawDirection = json['direction'];
    final rawUrl = json['download_url'];
    // لینک manifest ممکن است خراب/قدیمی/نسبی باشد؛ لینک اصلی همیشه از روی
    // کد زبان ساخته می‌شود و لینک manifest فقط پشتیبان است.
    var manifestUrl = rawUrl is String ? rawUrl.trim() : '';
    if (manifestUrl.isNotEmpty && !manifestUrl.startsWith('http')) {
      manifestUrl =
          '$kLangPacksBaseUrl/${manifestUrl.split('/').last}';
    }
    return LanguagePack(
      code: code,
      name: rawName is String && rawName.trim().isNotEmpty
          ? cleanLocalizedLabel(rawName)
          : code,
      flag: flagAssetForLanguageCode(code),
      downloadUrl: langPackUrlFor(code),
      fallbackUrl: manifestUrl == langPackUrlFor(code) ? '' : manifestUrl,
      direction: rawDirection == 'rtl' ? 'rtl' : 'ltr',
      stringCount: (json['string_count'] ?? json['strings']) is num
          ? ((json['string_count'] ?? json['strings']) as num).toInt()
          : 0,
      sizeBytes: json['size'] is num ? (json['size'] as num).toInt() : 0,
      sha256: json['sha256']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
    );
  }
}

/// Persian and English remain part of the executable UI. Every other
/// language is downloaded from the remote release manifest.
final List<LanguagePack> builtInLanguages = [
  LanguagePack(
    code: 'fa',
    name: 'فارسی',
    flag: flagAssetForLanguageCode('fa'),
    downloadUrl: '',
    direction: 'rtl',
  ),
  LanguagePack(
    code: 'en',
    name: 'English',
    flag: flagAssetForCountryCode('US'),
    downloadUrl: '',
    direction: 'ltr',
  ),
];

const _nativeLanguageNames = <String, String>{
  'ar': 'العربية',
  'cs': 'Čeština',
  'da': 'Dansk',
  'de': 'Deutsch',
  'el': 'Ελληνικά',
  'en': 'English',
  'es': 'Español',
  'fa': 'فارسی',
  'fi': 'Suomi',
  'fr': 'Français',
  'he': 'עברית',
  'hi': 'हिन्दी',
  'hu': 'Magyar',
  'id': 'Bahasa Indonesia',
  'it': 'Italiano',
  'ja': '日本語',
  'ko': '한국어',
  'nl': 'Nederlands',
  'no': 'Norsk',
  'pl': 'Polski',
  'pt': 'Português',
  'ro': 'Română',
  'ru': 'Русский',
  'sv': 'Svenska',
  'th': 'ไทย',
  'tr': 'Türkçe',
  'uk': 'Українська',
  'ur': 'اردو',
  'vi': 'Tiếng Việt',
  'zh': '中文',
};

/// وقتی manifest در دسترس نیست، فهرست زبان‌ها از کدهای شناخته‌شده ساخته می‌شود.
List<LanguagePack> fallbackRemoteLanguages() => [
      for (final entry in _nativeLanguageNames.entries)
        if (entry.key != 'fa' && entry.key != 'en')
          LanguagePack(
            code: entry.key,
            name: entry.value,
            flag: flagAssetForLanguageCode(entry.key),
            downloadUrl: langPackUrlFor(entry.key),
            direction: const {'ar', 'he', 'ur'}.contains(entry.key)
                ? 'rtl'
                : 'ltr',
          ),
    ];
