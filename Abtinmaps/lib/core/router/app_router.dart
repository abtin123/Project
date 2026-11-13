import 'package:go_router/go_router.dart';

import '../../features/map/presentation/home_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/settings/presentation/map_settings_screen.dart';
import '../../features/settings/presentation/marker_settings_screen.dart';
import '../../features/settings/presentation/appearance_settings_screen.dart';
import '../../features/settings/presentation/route_settings_screen.dart';
import '../../features/hud/presentation/hud_settings_screen.dart';
import '../../features/hud/presentation/hud_display_screen.dart';
import '../../features/ar/presentation/ar_navigation_screen.dart';
import '../../features/voice_settings/presentation/voice_settings_screen.dart';
import '../../features/saved_places/presentation/saved_places_screen.dart';
import '../../features/language_settings_hub/language_hub_screen.dart';

bool _isExternalNavigationUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'geo' || scheme == 'google.navigation' || scheme == 'abtin') {
    return true;
  }
  if (scheme == 'https') {
    final host = uri.host.toLowerCase();
    final mapsHost = host == 'google.com' ||
        host == 'www.google.com' ||
        host == 'maps.google.com' ||
        host == 'maps.app.goo.gl';
    return mapsHost &&
        (uri.path.toLowerCase().startsWith('/maps') ||
            uri.queryParameters.containsKey('destination') ||
            uri.queryParameters.containsKey('q') ||
            uri.queryParameters.containsKey('query'));
  }
  return false;
}

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  redirect: (context, state) {
    return _isExternalNavigationUri(state.uri) ? '/' : null;
  },
  errorBuilder: (context, state) => const HomeScreen(),
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(
        path: '/settings', builder: (context, state) => const SettingsScreen()),
    GoRoute(
      path: '/map-settings',
      builder: (context, state) => const MapSettingsScreen(),
    ),
    GoRoute(
      path: '/marker-settings',
      builder: (context, state) => const MarkerSettingsScreen(),
    ),
    GoRoute(
      path: '/appearance-settings',
      builder: (context, state) => const AppearanceSettingsScreen(),
    ),
    GoRoute(
      path: '/route-settings',
      builder: (context, state) => const RouteSettingsScreen(),
    ),
    GoRoute(
      path: '/hud-settings',
      builder: (context, state) => const HudSettingsScreen(),
    ),
    GoRoute(
      path: '/hud-display',
      builder: (context, state) => const HudDisplayScreen(),
    ),
    GoRoute(
      path: '/ar-navigation',
      builder: (context, state) => const ArNavigationScreen(),
    ),
    GoRoute(
      path: '/voice-settings',
      builder: (context, state) => const VoiceSettingsScreen(),
    ),
    GoRoute(
      path: '/saved-places',
      builder: (context, state) => const SavedPlacesScreen(),
    ),
    GoRoute(
      path: '/downloads',
      builder: (context, state) => const LanguageHubScreen(),
    ),
  ],
);
