import 'package:flutter/material.dart';
import '../../../core/localization/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:math' as math;
import '../../../core/theme/app_colors.dart';
import '../../map/presentation/destination_provider.dart';
import '../../gps/presentation/gps_providers.dart';
import '../data/place_search_service.dart';
import 'search_providers.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';
import 'package:abtin_maps/core/geo/geo_types.dart';
import '../../../core/database/app_database.dart';
import '../../history/presentation/history_providers.dart';
import '../../saved_places/presentation/home_work_widgets.dart';

/// دکمهٔ گرد شناور سرچ در نوار پایین. با لمس، جستجوی تمام‌صفحه را باز می‌کند.
class SearchLaunchButton extends ConsumerWidget {
  const SearchLaunchButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () {
        ref.read(searchActiveProvider.notifier).state = true;
        if (GoRouterState.of(context).uri.path != '/') {
          context.go('/');
        }
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 55,
        height: 75,
        child: Center(
          child: SizedBox(
            width: 44,
            height: 44,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.subGlassBg(context),
              ),
              child: AppIcon(
                Icons.search_rounded,
                size: 24,
                color: AppColors.textSecondary(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// لایهٔ کامل جستجو: نوار بالا با اینپوت زنده، و کارت‌های نتیجه با اسلاید
/// که هم روی نقشه پین می‌گذارند و هم گزینهٔ «مسیریابی»/«ارسال» دارند.
class SearchOverlay extends ConsumerStatefulWidget {
  const SearchOverlay({super.key});

  @override
  ConsumerState<SearchOverlay> createState() => _SearchOverlayState();
}

class _SearchOverlayState extends ConsumerState<SearchOverlay> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late final PageController _pageController;
  String _lastPinnedResultsKey = '';

  /// True while the selected destination is only a search preview pin.
  bool _previewPinned = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(searchQueryProvider));
    _focusNode = FocusNode();
    _pageController = PageController(viewportFraction: 0.88);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// Drops the preview pin created by the search so cancelling/back does not
  /// leave a destination behind (which would keep route calculation running).
  void _clearPreviewPin() {
    if (!_previewPinned) return;
    _previewPinned = false;
    ref.read(selectedDestinationProvider.notifier).state = null;
  }

  void _close({bool keepDestination = false}) {
    if (!keepDestination) _clearPreviewPin();
    _previewPinned = false;
    ref.read(searchActiveProvider.notifier).state = false;
    ref.read(searchAssignTargetProvider.notifier).state = null;
    ref.read(searchQueryProvider.notifier).state = '';
    ref.read(searchSubmittedQueryProvider.notifier).state = '';
    _controller.clear();
    _lastPinnedResultsKey = '';
  }

  /// Runs the search. Called only by the keyboard's Enter/Search key or the
  /// search button — never while typing.
  void _submit() {
    final query = _controller.text.trim();
    if (query.length < 2) return;
    _lastPinnedResultsKey = '';
    ref.read(searchQueryProvider.notifier).state = _controller.text;
    final submitted = ref.read(searchSubmittedQueryProvider.notifier);
    if (submitted.state == query) {
      // Same text again: run it again (e.g. after a network failure).
      ref.invalidate(searchResultsProvider);
    } else {
      submitted.state = query;
    }
    _focusNode.unfocus();
  }

  void _onTextChanged(String value) {
    ref.read(searchQueryProvider.notifier).state = value;
    if (value.trim().isEmpty) {
      ref.read(searchSubmittedQueryProvider.notifier).state = '';
      _lastPinnedResultsKey = '';
      _clearPreviewPin();
    }
  }

  void _pinSearchResult(PlaceSearchResult place, {bool autoStart = false}) {
    _previewPinned = true;
    ref.read(selectedDestinationProvider.notifier).state = SelectedDestination(
      place.point,
      label: place.name,
      autoStart: autoStart,
    );
  }

  void _selectPlace(PlaceSearchResult place, {bool startNavigation = false}) {
    // حالت «تعریف خانه/محل کار»: نتیجهٔ انتخاب‌شده ذخیره می‌شود، نه مسیریابی.
    final assign = ref.read(searchAssignTargetProvider);
    if (assign != null) {
      saveHomeWork(
        context,
        ref,
        category: assign,
        latitude: place.point.latitude,
        longitude: place.point.longitude,
        address: place.name,
      );
      _close();
      return;
    }
    _recordSearch(place);
    _pinSearchResult(place, autoStart: startNavigation);
    _close(keepDestination: true);
  }

  /// نتیجهٔ انتخاب‌شده را در «سابقهٔ جستجو» ذخیره می‌کند.
  void _recordSearch(PlaceSearchResult place) {
    final submitted = ref.read(searchSubmittedQueryProvider).trim();
    ref.read(historyRepositoryProvider).addSearch(
          query: submitted,
          title: place.name,
          subtitle: place.region,
          latitude: place.point.latitude,
          longitude: place.point.longitude,
          isOffline: place.isOffline,
        );
  }

  int _historyTab = 0; // 0 = جستجوها، 1 = مسیرها

  void _openSearchHistory(SearchHistoryData h) {
    ref.read(historyRepositoryProvider).addSearch(
          query: h.query,
          title: h.title,
          subtitle: h.subtitle,
          latitude: h.latitude,
          longitude: h.longitude,
          isOffline: h.isOffline,
        );
    _previewPinned = true;
    ref.read(selectedDestinationProvider.notifier).state = SelectedDestination(
      LatLng(h.latitude, h.longitude),
      label: h.title,
    );
    _close(keepDestination: true);
  }

  void _openRouteHistory(RouteHistoryData r) {
    ref.read(selectedDestinationProvider.notifier).state = SelectedDestination(
      LatLng(r.endLat, r.endLng),
      label: r.endLabel,
      autoStart: true,
    );
    _close(keepDestination: true);
  }

  Widget _emptyHistory(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Center(
          child: Text(
            AppStrings.get(context, ref, 'no_history_yet'),
            style:
                TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
          ),
        ),
      );

  Widget _buildIdlePanel(BuildContext context) {
    final assign = ref.watch(searchAssignTargetProvider);
    final searches =
        ref.watch(searchHistoryListProvider).valueOrNull ?? const <SearchHistoryData>[];
    final routes =
        ref.watch(routeHistoryListProvider).valueOrNull ?? const <RouteHistoryData>[];
    final accent = AppColors.primaryAccent(context);

    final children = <Widget>[];
    if (assign != null) {
      children.add(Row(
        children: [
          AppIcon(assign == 'home' ? Icons.home_rounded : Icons.work_rounded,
              color: accent, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              AppStrings.get(context, ref,
                  assign == 'home' ? 'assign_home_hint' : 'assign_work_hint'),
              style: TextStyle(
                  color: AppColors.textPrimary(context), fontSize: 13.5),
            ),
          ),
          TextButton(
            onPressed: () =>
                ref.read(searchAssignTargetProvider.notifier).state = null,
            child: Text(AppStrings.get(context, ref, 'cancel')),
          ),
        ],
      ));
    } else {
      children.add(HomeWorkChips(
        onNavigated: () => _close(keepDestination: true),
        onSearchAddress: () => _focusNode.requestFocus(),
      ));
      children.add(const SizedBox(height: 12));
      children.add(Row(
        children: [
          for (final t in const [0, 1])
            Expanded(
              child: Padding(
                padding: EdgeInsetsDirectional.only(end: t == 0 ? 8 : 0),
                child: ChoiceChip(
                  showCheckmark: false,
                  selected: _historyTab == t,
                  onSelected: (_) => setState(() => _historyTab = t),
                  avatar: Icon(
                      t == 0 ? Icons.history_rounded : Icons.alt_route_rounded,
                      size: 18,
                      color: _historyTab == t
                          ? Colors.white
                          : AppColors.textSecondary(context)),
                  label: SizedBox(
                    width: double.infinity,
                    child: Text(
                      AppStrings.get(context, ref,
                          t == 0 ? 'recent_searches' : 'recent_routes'),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _historyTab == t
                              ? Colors.white
                              : AppColors.textPrimary(context),
                          fontSize: 12.5),
                    ),
                  ),
                  selectedColor: accent,
                ),
              ),
            ),
        ],
      ));
      if (_historyTab == 0) {
        if (searches.isNotEmpty) {
          children.add(_HistoryHeader(
            title: AppStrings.get(context, ref, 'recent_searches'),
            clearLabel: AppStrings.get(context, ref, 'clear_history'),
            onClear: () => ref.read(historyRepositoryProvider).clearSearches(),
          ));
          for (final h in searches.take(8)) {
            children.add(_HistoryTile(
              icon: Icons.history_rounded,
              title: h.title,
              subtitle: h.subtitle,
              onTap: () => _openSearchHistory(h),
              onDelete: () =>
                  ref.read(historyRepositoryProvider).removeSearch(h.id),
            ));
          }
        } else {
          children.add(_emptyHistory(context));
        }
      } else {
        if (routes.isNotEmpty) {
          children.add(_HistoryHeader(
            title: AppStrings.get(context, ref, 'recent_routes'),
            clearLabel: AppStrings.get(context, ref, 'clear_history'),
            onClear: () => ref.read(historyRepositoryProvider).clearRoutes(),
          ));
          for (final r in routes.take(8)) {
            children.add(_HistoryTile(
              icon: Icons.alt_route_rounded,
              title: (r.endLabel?.trim().isNotEmpty == true)
                  ? r.endLabel!
                  : AppStrings.get(context, ref, 'route_history_unnamed'),
              subtitle: _formatStamp(r.createdAt),
              onTap: () => _openRouteHistory(r),
              onDelete: () =>
                  ref.read(historyRepositoryProvider).removeRoute(r.id),
            ));
          }
        } else {
          children.add(_emptyHistory(context));
        }
      }
    }

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.glassPanel(context),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: accent.withOpacity(0.25)),
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(12),
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _sharePlace(PlaceSearchResult place) {
    final url =
        'https://www.google.com/maps/search/?api=1&query=${place.point.latitude},${place.point.longitude}';
    SharePlus.instance.share(ShareParams(text: url, subject: place.name));
  }

  @override
  Widget build(BuildContext context) {
    final resultsAsync = ref.watch(searchResultsProvider);
    final selectedIndex = ref.watch(searchSelectedIndexProvider);
    final currentPosition = ref.watch(vehiclePositionProvider).valueOrNull;
    final topInset = MediaQuery.of(context).padding.top;

    // لایه فقط روی نوار جستجو و کارت‌های نتیجه لمس می‌گیرد؛ بقیهٔ صفحه
    // شفاف و بدون پوشش است تا نقشه زیرش قابل جابه‌جایی/زوم باشد.
    return SafeArea(
        child: Column(
          children: [
            // نوار جستجوی بازشده — دقیقاً جای دکمهٔ سرچ کوچک قبلی
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Material(
                type: MaterialType.transparency,
                child: _SearchInputBar(
                  controller: _controller,
                  focusNode: _focusNode,
                  onChanged: _onTextChanged,
                  onSubmit: _submit,
                  onBack: _close,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: resultsAsync.when(
                loading: () => ref.watch(searchSubmittedQueryProvider).length < 2
                    ? _buildIdlePanel(context)
                    : const Padding(
                        padding: EdgeInsets.only(top: 24),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        ),
                      ),
                error: (err, _) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    AppStrings.literal('خطا در جستجو، دوباره امتحان کنید'),
                    style: TextStyle(color: AppColors.textSecondary(context)),
                  ),
                ),
                data: (results) {
                  if (results.isEmpty) {
                    if (ref.watch(searchSubmittedQueryProvider).trim().length <
                        2) {
                      return _buildIdlePanel(context);
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Material(
                          type: MaterialType.transparency,
                          child: Text(
                            AppStrings.literal('نتیجه‌ای پیدا نشد'),
                            style: TextStyle(
                                color: AppColors.textSecondary(context)),
                          ),
                        ),
                      ),
                    );
                  }

                  // نتیجهٔ اول باید همان لحظه روی نقشه پین شود؛ کاربر لازم
                  // نیست ابتدا کارت را لمس کند. کلید نتایج جلوی اجرای مجدد
                  // این کار در هر rebuild را می‌گیرد.
                  final resultsKey = results
                      .map((place) =>
                          '${place.point.latitude.toStringAsFixed(6)},${place.point.longitude.toStringAsFixed(6)}:${place.name}')
                      .join('|');
                  if (_lastPinnedResultsKey != resultsKey) {
                    _lastPinnedResultsKey = resultsKey;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || results.isEmpty) return;
                      ref.read(searchSelectedIndexProvider.notifier).state = 0;
                      if (_pageController.hasClients) {
                        _pageController.jumpToPage(0);
                      }
                      _pinSearchResult(results.first);
                    });
                  }

                  return Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).padding.bottom + 24,
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: SizedBox(
                        height: 168,
                        child: PageView.builder(
                          controller: _pageController,
                          itemCount: results.length,
                          onPageChanged: (index) {
                            ref
                                .read(searchSelectedIndexProvider.notifier)
                                .state = index;
                            // با هر اسلاید، پین و مقصد نقشه هم‌زمان عوض می‌شود.
                            // listener مقصد در HomeScreen دوربین را روی همین
                            // نقطه می‌برد و OnlineMapView پین را در همان نقطه
                            // دوباره projection می‌کند.
                            if (index >= 0 && index < results.length) {
                              _pinSearchResult(results[index]);
                            }
                          },
                          itemBuilder: (context, index) {
                            final place = results[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 8),
                              child: _PlaceResultCard(
                                place: place,
                                index: index,
                                onTapCard: () => _selectPlace(place),
                                distanceMeters: currentPosition == null
                                    ? place.distanceMeters
                                    : _distanceMeters(
                                        currentPosition.lat,
                                        currentPosition.lng,
                                        place.point.latitude,
                                        place.point.longitude,
                                      ),
                                onRoute: () =>
                                    _selectPlace(place, startNavigation: true),
                                onShare: () => _sharePlace(place),
                              ),
                            );
                          },
                        ),
                      ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
    );
  }
}

class _SearchInputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;
  final VoidCallback onBack;

  const _SearchInputBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmit,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: AppColors.glassPanel(context),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: AppColors.primaryAccent(context).withOpacity(0.55),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryAccent(context).withOpacity(0.18),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: AppIcon(Icons.arrow_back_rounded,
                color: AppColors.textPrimary(context)),
            onPressed: onBack,
          ),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                onSubmitted: (_) => onSubmit(),
                textInputAction: TextInputAction.search,
                style: TextStyle(
                    color: AppColors.textPrimary(context), fontSize: 16),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: AppStrings.literal('جستجوی مکان یا آدرس…'),
                  hintStyle: TextStyle(color: AppColors.textSecondary(context)),
                ),
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onSubmit,
            child: Container(
              width: 42,
              height: 42,
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.primaryGradient(context),
              ),
              child: AppIcon(Icons.search_rounded,
                  color: AppColors.primaryOnAccent(context), size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDistance(double meters) {
  if (!meters.isFinite || meters < 0) return '';
  if (meters < 1000) return '${meters.round()} m';
  final km = meters / 1000.0;
  final digits = km < 10 ? 1 : 0;
  return '${km.toStringAsFixed(digits)} km';
}

double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const radius = 6371000.0;
  final p1 = lat1 * math.pi / 180.0;
  final p2 = lat2 * math.pi / 180.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(p1) * math.cos(p2) *
          math.sin(dLng / 2) * math.sin(dLng / 2);
  return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class _PlaceResultCard extends StatelessWidget {
  final PlaceSearchResult place;
  final int index;
  final VoidCallback onTapCard;
  final double? distanceMeters;
  final VoidCallback onRoute;
  final VoidCallback onShare;

  const _PlaceResultCard({
    required this.place,
    required this.index,
    required this.onTapCard,
    this.distanceMeters,
    required this.onRoute,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTapCard,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.glassPanel(context),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: AppColors.primaryAccent(context).withOpacity(0.3),
          ),
          boxShadow: const [
            BoxShadow(
                color: Colors.black45, blurRadius: 20, offset: Offset(0, 8)),
          ],
        ),
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primaryAccent(context).withOpacity(0.2),
                    ),
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: AppColors.primaryAccent(context),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textPrimary(context),
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        if (distanceMeters != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              _formatDistance(distanceMeters!),
                              style: TextStyle(
                                color: AppColors.primaryAccent(context),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        if (place.region != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              place.region!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textSecondary(context),
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onShare,
                      icon: AppIcon(Icons.ios_share_rounded,
                          size: 16, color: AppColors.textSecondary(context)),
                      label: Text(AppStrings.literal('ارسال'),
                          style: TextStyle(
                              color: AppColors.textSecondary(context))),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                            color: AppColors.textSecondary(context)
                                .withOpacity(0.4)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: onRoute,
                      icon: const AppIcon(Icons.alt_route_rounded, size: 18),
                      label: Text(AppStrings.literal('مسیریابی')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryAccent(context),
                        foregroundColor: AppColors.primaryOnAccent(context),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}


String _formatStamp(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}/${two(d.month)}/${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
}

class _HistoryHeader extends StatelessWidget {
  final String title;
  final String clearLabel;
  final VoidCallback onClear;
  const _HistoryHeader({
    required this.title,
    required this.clearLabel,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
                color: AppColors.textSecondary(context),
                fontWeight: FontWeight.w700,
                fontSize: 12.5),
          ),
        ),
        GestureDetector(
          onTap: onClear,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(
              clearLabel,
              style: TextStyle(
                  color: AppColors.primaryAccent(context), fontSize: 12.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _HistoryTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final sub = subtitle?.trim();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            AppIcon(icon,
                size: 22, color: AppColors.primaryAccent(context)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 14)),
                  if (sub != null && sub.isNotEmpty)
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppColors.textSecondary(context),
                            fontSize: 11.5)),
                ],
              ),
            ),
            GestureDetector(
              onTap: onDelete,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.close_rounded,
                    size: 18, color: AppColors.textSecondary(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
