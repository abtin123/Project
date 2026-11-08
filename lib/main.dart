import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/gps/presentation/gps_providers.dart';
import 'shared/providers/app_settings_providers.dart';
import 'features/settings/presentation/appearance_settings_providers.dart';
import 'core/deep_link/deep_link_service.dart';
import 'core/localization/app_localizations.dart';
import 'features/map/presentation/destination_provider.dart';
import 'features/routing/presentation/routing_providers.dart';
import 'features/language_settings/presentation/language_pack_providers.dart';
import 'package:abtin_maps/core/geo/geo_types.dart';
import 'shared/providers/abtinmap_providers.dart';

void _installCrashReporting() {
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    return true;
  };
  final originalOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    originalOnError?.call(details);
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Container(
      color: Colors.black,
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
      child: SingleChildScrollView(
        child: Text(
          details.exceptionAsString(),
          textDirection: TextDirection.ltr,
          style: const TextStyle(
            color: Color(0xFFFF5252),
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  };
}

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    _installCrashReporting();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );
    runApp(const ProviderScope(child: AbtinApp()));
  }, (error, stack) {
  });
}

class AbtinApp extends ConsumerStatefulWidget {
  const AbtinApp({super.key});

  @override
  ConsumerState<AbtinApp> createState() => _AbtinAppState();
}

class _AbtinAppState extends ConsumerState<AbtinApp>
    with WidgetsBindingObserver {
  bool _locationSuspendedForBackground = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final locationService = ref.read(locationServiceProvider);
    final navigationActive = ref.read(activeNavigationProvider) != null;
    if (state == AppLifecycleState.resumed) {
      ref.read(locationLifecycleTickProvider.notifier).state++;
      if (_locationSuspendedForBackground) {
        _locationSuspendedForBackground = false;
        locationService.start();
      } else {
        locationService.ensureAlive();
      }
      return;
    }
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        !navigationActive) {
      locationService.stop();
      _locationSuspendedForBackground = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final initAsync = ref.watch(appSettingsInitProvider);

    ref.watch(jointKalmanEnabledEffectProvider);

    ref.listen(activeNavigationProvider, (previous, next) {
      ref.read(locationServiceProvider).setNavigationMode(next != null);
    });
    ref.read(locationServiceProvider).setNavigationMode(
        ref.read(activeNavigationProvider) != null);

    ref.listen(deepLinkDestinationProvider, (previous, next) {
      next.whenData((dest) {
        ref.read(selectedDestinationProvider.notifier).state =
            SelectedDestination(
          LatLng(dest.lat, dest.lng),
          label: dest.label,
          autoStart: true,
        );
      });
    });

    return initAsync.when(
      data: (_) => _buildApp(context, ref),
      loading: () => const _SplashApp(),
      error: (_, __) => _buildApp(context, ref),
    );
  }

  Widget _buildApp(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final lang = ref.watch(languageProvider);
    AppStrings.setLanguage(lang);
    final primaryColor = ref.watch(primaryColorProvider);
    final appearance = ref.watch(appearanceSettingsProvider);
    final fontColorOverride =
        appearance.appFontColor.alpha == 0 ? null : appearance.appFontColor;
    final fontWeightOverride = appearance.appFontWeightOption.flutterWeight;
    final fontSizeFactor = appearance.appFontSizePercent / 100.0;
    final downloadedLanguageCodes = ref.watch(downloadedLanguagesProvider);
    final supportedLanguageCodes = <String>{
      'fa',
      'en',
      ...downloadedLanguageCodes
    };

    return MaterialApp.router(
      title: AppStrings.get(context, ref, 'app_name'),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(
        Brightness.light,
        primaryColor,
        fontColorOverride: fontColorOverride,
        fontWeightOverride: fontWeightOverride,
        fontSizeFactor: 1.0,
        fontFamily: appearance.appFontFamily.flutterFamily,
      ),
      darkTheme: AppTheme.build(
        Brightness.dark,
        primaryColor,
        fontColorOverride: fontColorOverride,
        fontWeightOverride: fontWeightOverride,
        fontSizeFactor: 1.0,
        fontFamily: appearance.appFontFamily.flutterFamily,
      ),
      themeMode: themeMode,
      routerConfig: appRouter,
      locale: Locale(lang),
      supportedLocales: [
        for (final code in supportedLanguageCodes) Locale(code),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final overlayStyle = SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness:
              isDark ? Brightness.light : Brightness.dark,
          systemNavigationBarDividerColor: Colors.transparent,
        );
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlayStyle,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(
                (MediaQuery.of(context)
                            .textScaler
                            .clamp(minScaleFactor: 0.85, maxScaleFactor: 1.15)
                            .scale(1.0) *
                        fontSizeFactor)
                    .clamp(0.75, 1.5),
              ),
            ),
            child: Directionality(
              textDirection: const {'fa', 'ar', 'he', 'ur'}.contains(lang)
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
}

class _SplashApp extends StatelessWidget {
  const _SplashApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Color(0xFF0A0D12),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF2FE6C4)),
        ),
      ),
    );
  }
}
