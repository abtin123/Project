import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../localization/app_localizations.dart';
import 'app_update_service.dart';

String _sizeLabel(int bytes) =>
    bytes <= 0 ? '' : ' (${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB)';

const String kAppPackageId = 'ir.abtin.abtin_maps';

/// لینک دانلود/به‌روزرسانی مایکت: اول اپ مایکت، بعد صفحهٔ وب مایکت، و در آخر
/// صفحهٔ release گیت‌هاب.
Future<void> openAppUpdate(AppUpdateInfo info) async {
  final targets = <Uri>[
    Uri.parse('myket://details?id=$kAppPackageId'),
    Uri.parse('https://myket.ir/app/$kAppPackageId'),
    Uri.parse(info.releasePageUrl),
  ];
  for (final uri in targets) {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
  }
}

/// پنجرهٔ هشدار به‌روزرسانی. true یعنی کاربر «به‌روزرسانی» را زد.
Future<bool> showAppUpdateDialog(BuildContext context, AppUpdateInfo info) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(AppStrings.literal('نسخهٔ جدید آبتین‌مپ')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'نسخهٔ ${info.latestVersion} منتشر شده است '
                '(نسخهٔ شما: ${info.currentVersion})'
                '${_sizeLabel(info.apkSizeBytes)}',
              ),
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  info.notes.length > 600
                      ? '${info.notes.substring(0, 600)}…'
                      : info.notes,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.literal('بعداً')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.literal('به‌روزرسانی')),
          ),
        ],
      ),
    ),
  );
  if (result == true) await openAppUpdate(info);
  return result == true;
}
