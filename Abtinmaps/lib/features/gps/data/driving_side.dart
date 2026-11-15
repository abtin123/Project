/// Which side of the road traffic keeps to, by ISO 3166-1 alpha-2 country code.
///
/// Used by the road snapper to pick the correct carriageway of a divided road
/// (the one on the right of the direction of travel in right-hand-traffic
/// countries, on the left in left-hand-traffic countries).
class DrivingSide {
  DrivingSide._();

  static const Set<String> leftHandCountries = {
    // Europe
    'GB', 'IE', 'MT', 'CY', 'GG', 'JE', 'IM', 'GI',
    // South & South-East Asia, East Asia
    'IN', 'PK', 'BD', 'LK', 'NP', 'BT', 'MV', 'TH', 'MY', 'SG', 'BN', 'ID',
    'TL', 'JP', 'HK', 'MO',
    // Africa
    'ZA', 'ZW', 'ZM', 'BW', 'NA', 'MZ', 'MW', 'KE', 'UG', 'TZ', 'SZ', 'LS',
    'MU', 'SC',
    // Oceania
    'AU', 'NZ', 'FJ', 'PG', 'WS', 'TO', 'KI', 'SB', 'NR', 'TV', 'CK', 'NU',
    // Americas / Caribbean
    'JM', 'BB', 'TT', 'GY', 'SR', 'BS', 'BM', 'KY', 'AG', 'DM', 'GD', 'KN',
    'LC', 'VC', 'AI', 'MS', 'VG', 'TC', 'FK',
  };

  static bool isLeftHandCountry(String? countryCode) {
    if (countryCode == null || countryCode.isEmpty) return false;
    return leftHandCountries.contains(countryCode.toUpperCase());
  }
}
