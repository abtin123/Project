library;

const Map<String, String> _languageToCountry = {
  'fa': 'IR',
  'en': 'GB',
  'ar': 'SA',
  'tr': 'TR',
  'ur': 'PK',
  'ku': 'IQ',
  'ps': 'AF',
  'ru': 'RU',
  'fr': 'FR',
  'de': 'DE',
  'es': 'ES',
  'it': 'IT',
  'zh': 'CN',
  'hi': 'IN',
  'az': 'AZ',
  'hy': 'AM',
  'ka': 'GE',
  'cs': 'CZ',
  'da': 'DK',
  'el': 'GR',
  'fi': 'FI',
  'he': 'IL',
  'hu': 'HU',
  'id': 'ID',
  'ja': 'JP',
  'ko': 'KR',
  'nl': 'NL',
  'no': 'NO',
  'pl': 'PL',
  'pt': 'PT',
  'ro': 'RO',
  'sv': 'SE',
  'th': 'TH',
  'uk': 'UA',
  'vi': 'VN',
};

const Set<String> _bundledFlagCountries = {
  'ir',
  'gb',
  'sa',
  'de',
  'tr',
  'pk',
  'iq',
  'af',
  'ru',
  'fr',
  'es',
  'it',
  'cn',
  'in',
  'az',
  'am',
  'ge',
  'jp',
  'kr',
  'nl',
  'be',
  'dk',
  'se',
  'no',
  'fi',
  'pl',
  'pt',
  'ro',
  'ua',
  'gr',
  'il',
  'id',
  'vn',
  'th',
  'cz',
  'hu',
  'us',
};

String flagAssetForCountryCode(String code) {
  final letters = RegExp(r'^[A-Za-z]{2}').stringMatch(code.trim());
  if (letters == null) return 'assets/images/flags/un.svg';
  final key = letters.toLowerCase();
  return _bundledFlagCountries.contains(key)
      ? 'assets/images/flags/$key.svg'
      : 'assets/images/flags/un.svg';
}

String flagAssetForLanguageCode(String code) {
  final normalized = code.trim().toLowerCase();
  if (normalized.isEmpty) return 'assets/images/flags/un.svg';
  final country = _languageToCountry[normalized] ?? normalized;
  return flagAssetForCountryCode(country);
}

String cleanLocalizedLabel(String raw) {
  var out = raw.trim();
  out = out.replaceAll(
      RegExp(r'[\(\[]\s*[a-zA-Z]{2,3}(?:[-_][a-zA-Z]{2,4})?\s*[\)\]]'), '');
  out = out.replaceAll(RegExp(r'[\s\-_]+[a-zA-Z]{2,3}$'), '');
  return out.trim();
}
