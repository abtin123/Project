import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:abtin_maps/core/geo/geo_types.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

import '../../../core/database/app_database.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../gps/presentation/gps_providers.dart';
import '../../map/presentation/destination_provider.dart';
import 'saved_places_providers.dart';

/// وقتی غیر null باشد («home» یا «work»)، انتخاب بعدیِ یک نتیجهٔ جستجو به‌جای
/// مسیریابی، آن مکان را به‌عنوان خانه/محل کار ذخیره می‌کند.
final searchAssignTargetProvider = StateProvider<String?>((ref) => null);

/// ذخیرهٔ موقعیت دلخواه به‌عنوان خانه یا محل کار ('home' | 'work').
Future<void> saveHomeWork(
  BuildContext context,
  WidgetRef ref, {
  required String category,
  required double latitude,
  required double longitude,
  String? address,
}) async {
  final name = AppStrings.get(
      context, ref, category == 'home' ? 'category_home' : 'category_work');
  final savedMsg = AppStrings.get(
      context, ref, category == 'home' ? 'home_saved' : 'work_saved');
  await ref.read(savedPlacesRepositoryProvider).setSpecial(
        category: category,
        name: name,
        latitude: latitude,
        longitude: longitude,
        address: address,
      );
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(savedMsg)));
  }
}

/// تعریف با موقعیت فعلی GPS.
Future<void> saveHomeWorkFromCurrentLocation(
  BuildContext context,
  WidgetRef ref,
  String category,
) async {
  final pos = ref.read(vehiclePositionProvider).valueOrNull;
  if (pos == null) {
    ScaffoldMessenger.maybeOf(context).let((m) => m.showSnackBar(SnackBar(
        content: Text(AppStrings.get(context, ref, 'no_gps_fix')))));
    return;
  }
  await saveHomeWork(context, ref,
      category: category, latitude: pos.lat, longitude: pos.lng);
}

extension _Let<T> on T? {
  void let(void Function(T) f) {
    final v = this;
    if (v != null) f(v);
  }
}

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _SheetOption({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        danger ? const Color(0xFFFF6B81) : AppColors.textPrimary(context);
    return ListTile(
      leading: AppIcon(icon, color: color, size: 24),
      title: Text(label, style: TextStyle(color: color, fontSize: 15)),
      onTap: onTap,
    );
  }
}

/// برگهٔ «تعریف/تغییر» خانه یا محل کار.
Future<void> showSetHomeWorkSheet(
  BuildContext context,
  WidgetRef ref, {
  required String category,
  VoidCallback? onSearchAddress,
}) {
  final title = AppStrings.get(
      context, ref, category == 'home' ? 'set_home_title' : 'set_work_title');
  final useCurrent = AppStrings.get(context, ref, 'use_current_location');
  final searchAddress = AppStrings.get(context, ref, 'search_address_option');
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(title,
                style: TextStyle(
                    color: AppColors.textPrimary(sheetCtx),
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
          ),
          _SheetOption(
            icon: Icons.my_location_rounded,
            label: useCurrent,
            onTap: () async {
              Navigator.pop(sheetCtx);
              await saveHomeWorkFromCurrentLocation(context, ref, category);
            },
          ),
          if (onSearchAddress != null)
            _SheetOption(
              icon: Icons.search_rounded,
              label: searchAddress,
              onTap: () {
                Navigator.pop(sheetCtx);
                ref.read(searchAssignTargetProvider.notifier).state = category;
                onSearchAddress();
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// برگهٔ عملیات برای خانه/محل کارِ تعریف‌شده: مسیریابی، تغییر، حذف.
Future<void> showHomeWorkActionsSheet(
  BuildContext context,
  WidgetRef ref, {
  required String category,
  required SavedPlace place,
  required VoidCallback onNavigate,
  VoidCallback? onSearchAddress,
}) {
  final title = AppStrings.get(
      context, ref, category == 'home' ? 'category_home' : 'category_work');
  final navLabel = AppStrings.get(context, ref, 'navigate_label');
  final changeLabel = AppStrings.get(context, ref, 'change_place');
  final removeLabel = AppStrings.get(context, ref, 'remove_place');
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(title,
                style: TextStyle(
                    color: AppColors.textPrimary(sheetCtx),
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
          ),
          _SheetOption(
            icon: Icons.navigation_rounded,
            label: navLabel,
            onTap: () {
              Navigator.pop(sheetCtx);
              onNavigate();
            },
          ),
          _SheetOption(
            icon: Icons.edit_rounded,
            label: changeLabel,
            onTap: () {
              Navigator.pop(sheetCtx);
              showSetHomeWorkSheet(context, ref,
                  category: category, onSearchAddress: onSearchAddress);
            },
          ),
          _SheetOption(
            icon: Icons.delete_outline_rounded,
            label: removeLabel,
            danger: true,
            onTap: () async {
              Navigator.pop(sheetCtx);
              await ref
                  .read(savedPlacesRepositoryProvider)
                  .removeCategory(category);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// دو دکمهٔ «خانه» و «محل کار». اگر تعریف نشده باشند، لمس آن‌ها برگهٔ تعریف را
/// باز می‌کند؛ اگر تعریف شده باشند، مسیریابی را شروع می‌کند (و آیکن مداد
/// برای تغییر/حذف است).
class HomeWorkChips extends ConsumerWidget {
  /// بعد از انتخاب مقصد (برای بستن جستجو یا رفتن به نقشه) صدا زده می‌شود.
  final VoidCallback onNavigated;

  /// فقط در جستجو: تعریف با «جستجوی آدرس».
  final VoidCallback? onSearchAddress;

  const HomeWorkChips({
    super.key,
    required this.onNavigated,
    this.onSearchAddress,
  });

  void _navigate(WidgetRef ref, SavedPlace place) {
    ref.read(selectedDestinationProvider.notifier).state = SelectedDestination(
      LatLng(place.latitude, place.longitude),
      label: place.name,
      autoStart: true,
    );
    onNavigated();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homePlaceProvider);
    final work = ref.watch(workPlaceProvider);
    Widget chip(String category, SavedPlace? place) {
      final isHome = category == 'home';
      return Expanded(
        child: _HomeWorkChip(
          icon: isHome ? Icons.home_rounded : Icons.work_rounded,
          title: AppStrings.get(
              context, ref, isHome ? 'category_home' : 'category_work'),
          subtitle: place == null
              ? AppStrings.get(context, ref,
                  isHome ? 'set_home_title' : 'set_work_title')
              : (place.address?.trim().isNotEmpty == true
                  ? place.address!
                  : AppStrings.get(context, ref, 'navigate_label')),
          defined: place != null,
          onTap: () {
            if (place == null) {
              showSetHomeWorkSheet(context, ref,
                  category: category, onSearchAddress: onSearchAddress);
            } else {
              _navigate(ref, place);
            }
          },
          onEdit: place == null
              ? null
              : () => showHomeWorkActionsSheet(
                    context,
                    ref,
                    category: category,
                    place: place,
                    onNavigate: () => _navigate(ref, place),
                    onSearchAddress: onSearchAddress,
                  ),
        ),
      );
    }

    return Row(
      children: [
        chip('home', home),
        const SizedBox(width: 10),
        chip('work', work),
      ],
    );
  }
}

class _HomeWorkChip extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool defined;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  const _HomeWorkChip({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.defined,
    required this.onTap,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primaryAccent(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onEdit,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.glassPanel(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: accent.withOpacity(defined ? 0.55 : 0.25), width: 1.2),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withOpacity(0.14),
              ),
              child: Center(child: AppIcon(icon, size: 22, color: accent)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 11.5)),
                ],
              ),
            ),
            if (onEdit != null)
              GestureDetector(
                onTap: onEdit,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.more_vert_rounded,
                      size: 20, color: AppColors.textSecondary(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
