# ارسال گزارش دیباگ

- دیباگر: تنظیمات ← «گزارش خطا (دیباگ)».
- «ارسال به توسعه‌دهنده»: همان لحظه لاگ را می‌فرستد.
- «ارسال خودکار گزارش مشکلات»: با رضایت کاربر؛ هنگام `STALL` یا `ERROR` (حداکثر هر ۱۰ دقیقه).
- مختصات به ~۱۰۰ متر گرد می‌شود و فقط ۵۰۰ خط آخر لاگ ارسال می‌شود.
- راه‌اندازی گیرنده: `tools/apps_script_debug_receiver.gs` را در Google Apps Script دیپلوی کنید
  و URL را در `ABTIN_DEBUG_ENDPOINT` بگذارید.

# iOS بدون امضا
`tools/github/build-ios-unsigned.yml` یک IPA امضا‌نشده می‌سازد (بدون Secret). برای نصب روی آیفون
باید با ابزارهایی مثل AltStore / Sideloadly (Apple ID رایگان) یا TrollStore امضا/نصب شود؛
انتشار در App Store حساب Apple Developer می‌خواهد.
