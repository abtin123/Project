import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/localization/locale_flags.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/providers/app_settings_providers.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/flag_avatar.dart';
import '../../../shared/providers/abtinmap_providers.dart';
import '../../../shared/providers/map_style_providers.dart';
import '../../routing/data/routing_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../data/map_catalog.dart';
import '../data/vector_map_service.dart';
import 'armenia_province_map.dart';
import 'iraq_province_map.dart';
import 'iran_province_map.dart';
import 'country_province_map.dart';
import 'country_vector_map.dart';
import 'map_download_providers.dart';
import 'offline_maps_providers.dart';
import 'province_download_card.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

class DownloadMapScreen extends ConsumerStatefulWidget {
  const DownloadMapScreen({super.key});

  @override
  ConsumerState<DownloadMapScreen> createState() => _DownloadMapScreenState();
}

enum _MapMode { online, offline }

enum _MapDownloadTab { downloaded, notDownloaded }

class _DownloadMapScreenState extends ConsumerState<DownloadMapScreen> {
  _MapDownloadTab _tab = _MapDownloadTab.notDownloaded;
  final Set<String> _expandedCountries = <String>{'IR'};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(catalogRefreshProvider.notifier).state++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEnglish = ref.watch(languageProvider) == 'en';

    if (_tab == _MapDownloadTab.downloaded) {
      final installedAsync = ref.watch(installedMapRegionsProvider);
      return Scaffold(
        backgroundColor: AppColors.background(context),
        appBar: PageHeader(
          title: AppStrings.get(context, ref, 'download_map_title'),
          backRoute: '/settings',
          highlight: true,
        ),
        body: SafeArea(
          top: false,
          child: installedAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _ErrorState(
              message: '$error',
              retryLabel: AppStrings.get(context, ref, 'downloads_retry'),
              onRetry: () => ref.invalidate(installedMapRegionsProvider),
            ),
            data: (regions) => _buildBody(context, regions, isEnglish),
          ),
        ),
      );
    }

    final catalogAsync = ref.watch(mapCatalogProvider);
    return Scaffold(
      backgroundColor: AppColors.background(context),
      appBar: PageHeader(
        title: AppStrings.get(context, ref, 'download_map_title'),
        backRoute: '/settings',
        highlight: true,
      ),
      body: SafeArea(
        top: false,
        child: catalogAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _ErrorState(
            message: '$error',
            retryLabel: AppStrings.get(context, ref, 'downloads_retry'),
            onRetry: () => ref.read(catalogRefreshProvider.notifier).state++,
          ),
          data: (catalog) => _buildBody(context, catalog.regions, isEnglish),
        ),
      ),
    );
  }

  Widget _buildBody(
      BuildContext context, List<MapRegion> regions, bool isEnglish) {
    final filtered = _tab == _MapDownloadTab.downloaded
        ? regions.where((r) {
            final installedIds =
                ref.watch(abmInstalledMapIdsProvider).valueOrNull ??
                    const <String>{};
            return installedIds.contains(r.id);
          }).toList()
        : (() {
            final installedIds =
                ref.watch(abmInstalledMapIdsProvider).valueOrNull ??
                    const <String>{};
            return regions
                .where((r) => !installedIds.contains(r.id))
                .toList();
          })();
    filtered.sort((a, b) => (isEnglish ? a.nameEn : a.name)
        .compareTo(isEnglish ? b.nameEn : b.name));
    final grouped = <String, List<MapRegion>>{};
    for (final region in filtered) {
      grouped.putIfAbsent(region.effectiveCountryCode, () => []).add(region);
    }
    final groupKeys = grouped.keys.toList()
      ..sort((a, b) {
        final left = grouped[a]!.first.displayCountryName(isEnglish);
        final right = grouped[b]!.first.displayCountryName(isEnglish);
        return left.compareTo(right);
      });
    final listChildren = <Widget>[
      _DownloadTabs(
        selected: _tab,
        downloadedLabel: AppStrings.get(context, ref, 'downloaded_ones'),
        notDownloadedLabel: AppStrings.get(context, ref, 'not_downloaded_ones'),
        onChanged: (value) {
          setState(() {
            _tab = value;
            if (value == _MapDownloadTab.notDownloaded) {
              _expandedCountries.add('IR');
            }
          });
        },
      ),
      const SizedBox(height: 12),
    ];
    for (final key in groupKeys) {
      final items = grouped[key]!
        ..sort((a, b) {
          final order = a.groupOrder.compareTo(b.groupOrder);
          return order != 0
              ? order
              : a
                  .displayRegionName(isEnglish)
                  .compareTo(b.displayRegionName(isEnglish));
        });
      final countryKey = key.toUpperCase();
      final isExpanded = _expandedCountries.contains(countryKey);

      listChildren
        ..add(
          _CountryAccordion(
            regions: items,
            allRegions: regions
                .where((r) => r.effectiveCountryCode == countryKey)
                .toList(),
            countryCode: countryKey,
            isEnglish: isEnglish,
            expanded: isExpanded,
            downloadedMode: _tab == _MapDownloadTab.downloaded,
            onToggle: () {
              setState(() {
                if (isExpanded) {
                  _expandedCountries.remove(countryKey);
                } else {
                  _expandedCountries.add(countryKey);
                }
              });
            },
          ),
        )
        ..add(const SizedBox(height: 12));
    }
    listChildren.add(const SizedBox(height: 8));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: listChildren.length,
      itemBuilder: (_, index) => listChildren[index],
    );
  }
}


class _CountryAccordion extends ConsumerWidget {
  const _CountryAccordion({
    required this.regions,
    required this.allRegions,
    required this.countryCode,
    required this.isEnglish,
    required this.expanded,
    required this.downloadedMode,
    required this.onToggle,
  });

  final List<MapRegion> regions;
  final List<MapRegion> allRegions;
  final String countryCode;
  final bool isEnglish;
  final bool expanded;
  final bool downloadedMode;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = AppColors.primaryAccent(context);
    final installedIds =
        ref.watch(abmInstalledMapIdsProvider).valueOrNull ?? const <String>{};
    final installedCount =
        regions.where((r) => installedIds.contains(r.id)).length;
    final isIran = countryCode == 'IR';
    final countryName = regions.first.displayCountryName(isEnglish);
    final countLabel = isIran
        ? AppStrings.getWithParams(
            context, ref, 'download_province_count', {'count': regions.length})
        : AppStrings.getWithParams(
            context, ref, 'download_region_count', {'count': regions.length});

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: const Color(0xFF05132A).withOpacity(.85),
        border: Border.all(color: const Color(0xFF2F5BFF), width: 1.3),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2F5BFF).withOpacity(.16),
            blurRadius: 16,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Row(
                    children: [
                      _FlagBadge(countryCode: countryCode, glow: expanded, large: true),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              countryName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              countLabel,
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (installedCount > 0 && !isIran)
                        Container(
                          margin: const EdgeInsetsDirectional.only(end: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF18B88A).withOpacity(.13),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$installedCount',
                            style: const TextStyle(
                              color: Color(0xFF3DDC84),
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      AppIcon(
                        expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: AppColors.textPrimary(context),
                        size: 31,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(
              height: 1,
              thickness: 1.1,
              color: Color(0xFF2F5BFF),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
              child: _CountryMapDownloadPanel(
                countryCode: countryCode,
                regions: regions,
                allRegions: allRegions,
                isEnglish: isEnglish,
                downloadedMode: downloadedMode,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CountryMapPreview extends ConsumerWidget {
  const _CountryMapPreview({
    required this.regions,
    required this.downloadedMode,
    required this.isEnglish,
  });

  final List<MapRegion> regions;
  final bool downloadedMode;
  final bool isEnglish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(abmInstalledMapIdsProvider).valueOrNull ??
        const <String>{};
    final updates = ref.watch(updatableMapIdsProvider).valueOrNull ??
        const <String>{};
    final code = regions.isEmpty ? 'IR' : regions.first.effectiveCountryCode;
    return CountryVectorMap(
      countryCode: code,
      regions: regions,
      installedIds: installed,
      updateIds: updates,
    );
  }
}

class _CountryRegionList extends StatelessWidget {
  const _CountryRegionList({required this.regions});

  final List<MapRegion> regions;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.black.withOpacity(.14),
        border: Border.all(color: AppColors.glassBorder(context)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < regions.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: AppColors.glassBorder(context).withOpacity(.55),
              ),
            _RegionDownloadTile(region: regions[i]),
          ],
        ],
      ),
    );
  }
}

class _CountryMapDownloadPanel extends ConsumerStatefulWidget {
  const _CountryMapDownloadPanel({
    required this.countryCode,
    required this.regions,
    required this.allRegions,
    required this.isEnglish,
    required this.downloadedMode,
  });

  final String countryCode;

  final List<MapRegion> regions;

  final List<MapRegion> allRegions;
  final bool isEnglish;
  final bool downloadedMode;

  @override
  ConsumerState<_CountryMapDownloadPanel> createState() =>
      _CountryMapDownloadPanelState();
}

class _CountryMapDownloadPanelState
    extends ConsumerState<_CountryMapDownloadPanel> {
  String? _selectedId;
  String? _selectedProvince;

  @override
  Widget build(BuildContext context) {
    final installed =
        ref.watch(abmInstalledMapIdsProvider).valueOrNull ?? const <String>{};
    final updatableIds =
        ref.watch(updatableMapIdsProvider).valueOrNull ?? const <String>{};
    final accent = AppColors.primaryAccent(context);
    final isIran = widget.countryCode == 'IR';

    final mapRegions = widget.downloadedMode ? widget.regions : widget.allRegions;
    final cardRegions = mapRegions.where((r) => r.id != 'iran').toList();

    Widget map;
    Widget? cards;
    if (isIran) {
      final byId = {for (final r in cardRegions) r.id: r};
      MapRegion? selected = byId[_selectedId];
      selected ??= cardRegions.cast<MapRegion?>().firstWhere(
            (r) => widget.downloadedMode || !installed.contains(r!.id),
            orElse: () => cardRegions.isEmpty ? null : cardRegions.first,
          );
      map = SizedBox(
        height: 350,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: IranProvinceMap(
            regions: mapRegions,
            isEnglish: widget.isEnglish,
            selectedId: selected?.id,
            showUpdates: widget.downloadedMode,
            onProvinceTap: (region) async {
              if (mounted) setState(() => _selectedId = region.id);
            },
          ),
        ),
      );
      if (selected != null) {
        cards = ProvinceDownloadCard(
          key: ValueKey(selected.id),
          region: selected,
          installed: installed.contains(selected.id),
          updatable: updatableIds.contains(selected.id),
          isEnglish: widget.isEnglish,
          downloadedTab: widget.downloadedMode,
        );
      }
    } else {
      final provinceData = kProvinceDataByCountry[widget.countryCode];
      final matched = provinceData == null
          ? const <String, MapRegion>{}
          : matchProvinceRegions(provinceData, mapRegions);

      MapRegion? selected;
      String? highlightId = _selectedProvince;
      if (matched.isNotEmpty) {
        selected = matched[_selectedProvince];
        selected ??= cardRegions.cast<MapRegion?>().firstWhere(
              (r) => widget.downloadedMode || !installed.contains(r!.id),
              orElse: () => cardRegions.isEmpty ? null : cardRegions.first,
            );
        highlightId = null;
        if (selected != null) {
          for (final e in matched.entries) {
            if (e.value.id == selected.id) highlightId = e.key;
          }
        }
      }

      void onTap(String id) {
        if (!mounted) return;
        if (matched.isNotEmpty && !matched.containsKey(id)) return;
        setState(() => _selectedProvince = id);
      }

      Widget framed(Widget child) => SizedBox(
            height: 350,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: child,
            ),
          );

      if (widget.countryCode == 'AM') {
        map = framed(ArmeniaProvinceMap(
          regions: mapRegions,
          installedIds: installed,
          updateIds: updatableIds,
          isEnglish: widget.isEnglish,
          selectedId: highlightId,
          showUpdates: widget.downloadedMode,
          onProvinceTap: onTap,
        ));
      } else if (widget.countryCode == 'IQ') {
        map = framed(IraqProvinceMap(
          regions: mapRegions,
          installedIds: installed,
          updateIds: updatableIds,
          isEnglish: widget.isEnglish,
          selectedId: highlightId,
          showUpdates: widget.downloadedMode,
          onProvinceTap: onTap,
        ));
      } else if (kCountryProvinceSpecs.containsKey(widget.countryCode)) {
        map = framed(CountryProvinceMap(
          spec: kCountryProvinceSpecs[widget.countryCode]!,
          regions: mapRegions,
          installedIds: installed,
          updateIds: updatableIds,
          isEnglish: widget.isEnglish,
          selectedId: highlightId,
          showUpdates: widget.downloadedMode,
          onProvinceTap: onTap,
        ));
      } else {
        map = CountryVectorMap(
          countryCode: widget.countryCode,
          regions: mapRegions,
          installedIds: installed,
          updateIds: updatableIds,
          showUpdates: widget.downloadedMode,
        );
      }

      if (matched.isNotEmpty) {
        if (selected != null) {
          cards = ProvinceDownloadCard(
            key: ValueKey(selected.id),
            region: selected,
            installed: installed.contains(selected.id),
            updatable: updatableIds.contains(selected.id),
            isEnglish: widget.isEnglish,
            downloadedTab: widget.downloadedMode,
          );
        }
      } else {
        cards = Column(
          children: [
            for (var i = 0; i < cardRegions.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              ProvinceDownloadCard(
                key: ValueKey(cardRegions[i].id),
                region: cardRegions[i],
                installed: installed.contains(cardRegions[i].id),
                updatable: updatableIds.contains(cardRegions[i].id),
                isEnglish: widget.isEnglish,
                downloadedTab: widget.downloadedMode,
              ),
            ],
          ],
        );
      }
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        color: const Color(0xFF020B19).withOpacity(.9),
        border: Border.all(color: const Color(0xFF2F5BFF), width: 1.4),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF2F5BFF).withOpacity(.14), blurRadius: 14),
        ],
      ),
      child: Column(
        children: [
          map,
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2F5BFF), width: 1.1),
            ),
            child: Directionality(
            textDirection: TextDirection.rtl,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 14,
              runSpacing: 6,
              children: [
                _LegendDot(
                    color: const Color(0xFFF5F7FB),
                    label: AppStrings.literal('آماده دانلود')),
                _LegendDot(
                    color: const Color(0xFF18B88A),
                    label: AppStrings.get(context, ref, 'map_downloaded')),
                if (widget.downloadedMode)
                  _LegendDot(
                      color: const Color(0xFF2E9BFF),
                      label:
                          AppStrings.get(context, ref, 'map_update_available')),
                _LegendDot(
                    color: const Color(0xFF6B6BFF),
                    label: AppStrings.literal('در حال دانلود')),
              ],
            ),
            ),
          ),
          if (cards != null) ...[
            const SizedBox(height: 12),
            cards,
          ],
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 13,
            height: 13,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
}

class _RegionDownloadTile extends ConsumerWidget {
  const _RegionDownloadTile({required this.region});

  final MapRegion region;

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  static String _formatSize(double mb) {
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    if (mb >= 1) return '${mb.toStringAsFixed(0)} MB';
    if (mb > 0) return '${(mb * 1024).toStringAsFixed(0)} KB';
    return '—';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final download = ref.watch(regionDownloadControllerProvider(region));
    final installed = ref
            .watch(abmInstalledMapIdsProviderFamily(region.id))
            .valueOrNull ??
        false;
    final updatable =
        ref.watch(updatableMapIdsProvider).valueOrNull?.contains(region.id) ??
            false;
    final isActive = installed;
    final isEnglish = ref.watch(languageProvider) == 'en';
    final accent = AppColors.primaryAccent(context);
    final totalBytes =
        region.totalSizeBytes > 0 ? region.totalSizeBytes : (download.total ?? 0);
    final staged = installed
        ? 0
        : (ref.watch(regionStagedBytesProvider(region)).valueOrNull ?? 0);
    final receivedBytes =
        download.received > staged ? download.received : staged;
    final hasPartial = !installed && !download.downloading && receivedBytes > 0;
    final progress = totalBytes > 0
        ? (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble()
        : download.fraction;
    final showProgress =
        (download.downloading || hasPartial) && progress != null;

    String status;
    if (download.downloading) {
      status = download.phase == RegionDownloadPhase.building
          ? AppStrings.get(context, ref, 'map_building')
          : download.phase == RegionDownloadPhase.saving
              ? AppStrings.get(context, ref, 'map_saving')
              : AppStrings.get(context, ref, 'map_downloading');
    } else if (hasPartial) {
      status = AppStrings.literal('متوقف‌شده');
    } else if (updatable) {
      status = AppStrings.get(context, ref, 'map_update_available');
    } else if (installed) {
      status = AppStrings.get(context, ref, 'map_downloaded');
    } else {
      status = AppStrings.get(context, ref, 'map_not_downloaded');
    }

    final primaryName = region.displayRegionName(isEnglish);
    final secondaryName = isEnglish ? region.name : region.nameEn;
    final showSecondary = secondaryName.trim().isNotEmpty &&
        secondaryName.trim() != primaryName.trim();
    const green = Color(0xFF3DDC84);
    final notifier = ref.read(regionDownloadControllerProvider(region).notifier);
    final VoidCallback? onPressed = download.downloading
        ? notifier.pause
        : updatable || !installed || hasPartial
            ? () => notifier.start()
            : null;

    final showActionButton =
        download.downloading || installed || updatable || !installed || hasPartial;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _FlagBadge(countryCode: region.effectiveCountryCode, glow: isActive),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      primaryName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    if (showSecondary) ...[
                      const SizedBox(height: 2),
                      Text(
                        secondaryName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      '${_formatSize(region.totalSizeMb)}  •  $status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isActive
                            ? green
                            : download.downloading || updatable || hasPartial
                                ? accent
                                : AppColors.textMuted(context),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (installed)
                IconButton(
                  tooltip: AppStrings.get(context, ref, 'map_delete_action'),
                  onPressed: download.downloading ? null : notifier.delete,
                  icon: AppIcon(Icons.delete_outline_rounded,
                      size: 20, color: AppColors.textMuted(context)),
                  visualDensity: VisualDensity.compact,
                ),
              const SizedBox(width: 4),
              if (showActionButton)
                OutlinedButton.icon(
                  onPressed: onPressed,
                  icon: AppIcon(
                    download.downloading
                        ? Icons.pause_rounded
                        : installed
                            ? Icons.system_update_alt_rounded
                            : hasPartial
                                ? Icons.play_arrow_rounded
                                : Icons.download_rounded,
                    size: 17,
                  ),
                  label: Text(
                    download.downloading
                        ? AppStrings.get(context, ref, 'map_pause_action')
                        : installed
                            ? AppStrings.get(context, ref, 'map_update_action')
                            : hasPartial
                                ? AppStrings.literal('ادامه')
                                : AppStrings.get(
                                    context, ref, 'map_download_action_short'),
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 13.5),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: installed
                        ? (updatable
                            ? const Color(0xFF2E9BFF)
                            : AppColors.textMuted(context))
                        : accent,
                    side: BorderSide(
                        color: installed
                            ? (updatable
                                ? const Color(0xFF2E9BFF)
                                : AppColors.textMuted(context).withOpacity(.35))
                            : accent.withOpacity(.75),
                        width: 1.3),
                    shape: const StadiumBorder(),
                    minimumSize: const Size(96, 46),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                ),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: 8),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 5,
                disabledActiveTrackColor: accent,
                disabledInactiveTrackColor:
                    AppColors.textMuted(context).withOpacity(.18),
                disabledThumbColor: accent,
                thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6, disabledThumbRadius: 6),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: SizedBox(
                height: 18,
                child: Slider(value: progress!, onChanged: null),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                      color: accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800),
                ),
                if (totalBytes > 0)
                  Flexible(
                    child: Text(
                      '${_fmtBytes(receivedBytes)} / ${_fmtBytes(totalBytes)}'
                      '  •  ${_fmtBytes((totalBytes - receivedBytes).clamp(0, totalBytes).toInt())} ${AppStrings.literal('مانده')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                          color: AppColors.textMuted(context), fontSize: 11),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeToggle extends ConsumerWidget {
  const _ModeToggle({required this.mode, required this.onChanged});

  final _MapMode mode;
  final ValueChanged<_MapMode> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Expanded(
          child: _ModeCard(
            selected: mode == _MapMode.online,
            icon: Icons.cloud_outlined,
            title: AppStrings.get(context, ref, 'map_mode_online'),
            subtitle: AppStrings.get(context, ref, 'map_mode_online_desc'),
            onTap: () => onChanged(_MapMode.online),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ModeCard(
            selected: mode == _MapMode.offline,
            icon: Icons.check_circle_rounded,
            title: AppStrings.get(context, ref, 'map_mode_offline'),
            subtitle: AppStrings.get(context, ref, 'map_mode_offline_desc'),
            onTap: () => onChanged(_MapMode.offline),
          ),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primaryAccent(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: selected
                ? accent.withOpacity(0.14)
                : AppColors.glassPanelSoft(context),
            border: Border.all(
              color: selected
                  ? accent.withOpacity(0.85)
                  : AppColors.glassBorder(context),
              width: selected ? 1.4 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: accent.withOpacity(0.28),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            children: [
              AppIcon(icon,
                  color: selected ? accent : AppColors.textSecondary(context),
                  size: 24),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  color: selected
                      ? AppColors.textPrimary(context)
                      : AppColors.textSecondary(context),
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textMuted(context),
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadTabs extends StatelessWidget {
  const _DownloadTabs({
    required this.selected,
    required this.downloadedLabel,
    required this.notDownloadedLabel,
    required this.onChanged,
  });

  final _MapDownloadTab selected;
  final String downloadedLabel;
  final String notDownloadedLabel;
  final ValueChanged<_MapDownloadTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: const Color(0xFF04132B).withOpacity(.85),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF2F5BFF), width: 1.2),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF2F5BFF).withOpacity(.18), blurRadius: 14),
        ],
      ),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Row(
          children: [
            Expanded(
              child: _DownloadTabButton(
                label: downloadedLabel,
                selected: selected == _MapDownloadTab.downloaded,
                onTap: () => onChanged(_MapDownloadTab.downloaded),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _DownloadTabButton(
                label: notDownloadedLabel,
                selected: selected == _MapDownloadTab.notDownloaded,
                onTap: () => onChanged(_MapDownloadTab.notDownloaded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadTabButton extends StatelessWidget {
  const _DownloadTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xFF4B2BD8), Color(0xFF2F7BFF)],
                  )
                : null,
            border: selected
                ? Border.all(color: const Color(0xFF4F8DFF), width: 1.2)
                : null,
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: const Color(0xFF3F6BFF).withOpacity(.45),
                        blurRadius: 14),
                  ]
                : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white.withOpacity(.82),
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
        ),
      );
}

class _CountryGroupHeader extends ConsumerWidget {
  const _CountryGroupHeader({required this.region, required this.count});

  final MapRegion region;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isEnglish = ref.watch(languageProvider) == 'en';
    final label = region.displayCountryName(isEnglish);
    return Row(
      children: [
        _FlagBadge(countryCode: region.effectiveCountryCode, glow: false),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: AppColors.textPrimary(context),
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Text(
          isEnglish ? '$count regions' : '$count بخش',
          style: TextStyle(
            color: AppColors.textMuted(context),
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _RegionCard extends StatelessWidget {
  const _RegionCard({required this.region});

  final MapRegion region;

  @override
  Widget build(BuildContext context) => _RegionDownloadTile(region: region);
}

class _DeleteButton extends ConsumerWidget {
  const _DeleteButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: AppColors.danger.withOpacity(0.14),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.danger.withOpacity(0.35)),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppIcon(Icons.delete_outline_rounded,
                    size: 17, color: AppColors.danger),
                const SizedBox(width: 6),
                Text(
                  AppStrings.get(context, ref, 'map_delete_action'),
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends ConsumerWidget {
  const _ActionButton({
    required this.isDownloading,
    required this.installed,
    required this.active,
    required this.updatable,
    required this.onActivate,
    required this.onTap,
  });

  final bool isDownloading;
  final bool installed;
  final bool active;
  final bool updatable;
  final Future<void> Function() onActivate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = AppColors.primaryAccent(context);

    IconData icon;
    String label;
    Color color;

    if (isDownloading) {
      icon = Icons.pause_rounded;
      label = AppStrings.get(context, ref, 'map_pause_action');
      color = accent;
    } else if (updatable) {
      icon = Icons.refresh_rounded;
      label = AppStrings.get(context, ref, 'map_update_action');
      color = accent;
    } else if (active) {
      icon = Icons.check_rounded;
      label = AppStrings.get(context, ref, 'active_label');
      color = const Color(0xFF3DDC84);
    } else if (installed) {
      icon = Icons.phone_android_rounded;
      label = AppStrings.get(context, ref, 'map_downloaded');
      color = AppColors.primaryAccent(context);
    } else {
      icon = Icons.download_rounded;
      label = AppStrings.get(context, ref, 'map_download_action');
      color = const Color(0xFF3DDC84);
    }

    final bool tappable = isDownloading || updatable || !installed || !active;

    return Material(
      color: color.withOpacity(0.16),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: !tappable
            ? null
            : () {
                if (installed && !active && !updatable) {
                  onActivate();
                } else {
                  onTap();
                }
              },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.45)),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(icon, size: 17, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlagBadge extends StatelessWidget {
  const _FlagBadge({
    required this.countryCode,
    required this.glow,
    this.large = false,
  });

  final String countryCode;
  final bool glow;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primaryAccent(context);
    final flagAsset = flagAssetForCountryCode(countryCode);
    final width = large ? 76.0 : 46.0;
    final height = large ? 52.0 : 34.0;
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: AppColors.glassPanel(context),
        border: Border.all(
          color: glow ? accent.withOpacity(.72) : AppColors.glassBorder(context),
          width: glow ? 1.3 : 1,
        ),
        boxShadow: glow
            ? [BoxShadow(color: accent.withOpacity(.20), blurRadius: 10)]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: FlagAvatar.rectangle(
          flag: flagAsset,
          width: large ? 68 : 40,
          height: large ? 44 : 28,
          size: large ? 44 : 28,
          borderRadius: BorderRadius.circular(7),
          semanticsLabel: 'پرچم $countryCode',
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState(
      {required this.message, required this.retryLabel, required this.onRetry});

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(Icons.wifi_off_rounded,
                size: 40, color: AppColors.textMuted(context)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary(context)),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const AppIcon(Icons.refresh_rounded),
              label: Text(retryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
