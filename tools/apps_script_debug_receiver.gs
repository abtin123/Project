/**
 * گیرندهٔ گزارش دیباگ AbtinMaps -> ایمیل به abtinmaps@gmail.com
 *
 * راه‌اندازی:
 * 1) https://script.google.com  ->  New project  ->  این کد را جایگذاری کنید.
 * 2) Deploy -> New deployment -> Type: Web app
 *      Execute as: Me (abtinmaps@gmail.com)
 *      Who has access: Anyone
 * 3) آدرس Web app را (که با https://script.google.com/macros/s/.../exec تمام می‌شود)
 *    در lib/core/debug/abtin_debug_reporter.dart به‌جای defaultValue خالی
 *    ABTIN_DEBUG_ENDPOINT بگذارید، یا هنگام بیلد:
 *      flutter build apk --dart-define=ABTIN_DEBUG_ENDPOINT=<URL>
 *
 * نکته: سهمیهٔ ایمیل روزانهٔ جیمیل معمولی حدود ۱۰۰ ایمیل است؛ اپ حداکثر هر ۱۰ دقیقه
 * یک گزارش خودکار از هر دستگاه می‌فرستد.
 */
var EXPECTED_TOKEN = 'abtin-debug-v1';
var TO_EMAIL = 'abtinmaps@gmail.com';

function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);
    if (data.token !== EXPECTED_TOKEN) {
      return ContentService.createTextOutput('forbidden');
    }
    var id = String(data.deviceId || '').slice(0, 6);
    var subject = '[AbtinMaps debug] ' + data.version + ' ' + data.reason + ' #' + id;
    var header =
      'app: ' + data.app + '\n' +
      'version: ' + data.version + '\n' +
      'platform: ' + data.platform + '\n' +
      'device: ' + data.deviceId + '\n' +
      'time: ' + data.time + '\n' +
      'reason: ' + data.reason + '\n\n';
    MailApp.sendEmail({
      to: TO_EMAIL,
      subject: subject,
      body: header + String(data.log || '').slice(-20000),
      attachments: [Utilities.newBlob(String(data.log || ''), 'text/plain', 'abtin_debug.log')]
    });
    return ContentService.createTextOutput('ok');
  } catch (err) {
    return ContentService.createTextOutput('error: ' + err);
  }
}
