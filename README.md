# Abtin Maps | آبتین مپس

**Offline-first navigation for Android, built with Flutter and OpenStreetMap data.**  
**مسیریاب آبتین؛ اپلیکیشن مسیریابی مبتنی بر Flutter و داده‌های OpenStreetMap، با تمرکز بر استفاده آفلاین.**

> **Project status / وضعیت پروژه:** This repository is an active development build. Some features and device-specific behavior still require testing. Do not assume every feature is production-ready.
>
> این مخزن نسخه‌ای در حال توسعه است. بعضی قابلیت‌ها و رفتارهای وابسته به دستگاه هنوز باید آزمایش شوند؛ بنابراین همه امکانات را آمادهٔ استفادهٔ نهایی فرض نکنید.

---

## English

### Overview

Abtin Maps is a navigation application project built with **Flutter and Dart**. It uses **MapLibre** to render map data and is designed to support online maps alongside locally stored map data. The project includes GPS positioning, route calculation components, saved places, map styling, and an augmented-reality (AR) camera screen.

The exact availability and reliability of features depend on the map data installed, network access, device permissions, and testing on the target device.

### Main features

- **Map rendering:** MapLibre-based map display and custom map styles.
- **OpenStreetMap data:** Supports map data derived from OpenStreetMap; attribution and source licensing must be preserved.
- **GPS positioning:** Current-location features and vehicle-position smoothing.
- **Routing components:** Online route requests and an offline-routing engine are present in the source. Offline routing quality depends on the installed map package and its road graph.
- **Route modes:** Fastest, shortest, and economical route modes are implemented in the project source; verify behavior on a real device before relying on them.
- **Saved places:** Local persistence for places and route-related data.
- **3D / vehicle visuals:** GLB model rendering and map 3D-building styling are included.
- **AR view:** A camera-based navigation screen is included. Camera permission is used for this screen.
- **Localization:** Persian and English resources are included, with a localization framework for the app.
- **Map and navigation preferences:** Custom map styling and navigation-related settings.

### Technology

- Flutter / Dart
- MapLibre GL for Flutter
- Riverpod for state management
- GoRouter for in-app navigation
- SQLite / Drift for local data
- Geolocator and permission_handler for location and permissions
- Camera plugin for the AR view
- `model_viewer_plus` for GLB model viewing

### Requirements

The release-build notes in this project specify the following toolchain:

- Flutter 3.35.1 stable
- Dart 3.9.0
- Android SDK Platform 36
- Android NDK 28.2.13676358
- Java / JDK 21

Compatible toolchain versions may change as the project evolves.

### Run locally

1. Install Flutter and the Android toolchain listed above.
2. Extract or clone this repository.
3. Open a terminal in the project root (the directory containing `pubspec.yaml`).
4. Fetch dependencies:

   ```bash
   flutter pub get
   ```

5. Check connected devices:

   ```bash
   flutter devices
   ```

6. Run the app:

   ```bash
   flutter run
   ```

### Build an Android release

Build an APK:

```bash
flutter pub get
flutter build apk --release
```

Build an Android App Bundle (for stores that accept AAB uploads):

```bash
flutter build appbundle --release
```

Typical output paths:

- APK: `build/app/outputs/flutter-apk/app-release.apk`
- AAB: `build/app/outputs/bundle/release/app-release.aab`

A successful compilation does not prove that GPS, routing, offline maps, AR, or every screen works correctly. Test the resulting build on a physical device.

### Maps and offline data

Map availability depends on the map packages supplied to the application. The source contains code for rendering local map data, but the presence of the code alone does not mean a usable offline map is bundled in every release.

Before publishing, verify that:

1. The intended regional map package is included or downloadable.
2. The map appears after installation and remains available without a network connection.
3. Offline search and offline routing work for the selected region.
4. Route direction, one-way roads, junctions, and road snapping are correct.
5. Required OpenStreetMap attribution is visible wherever applicable.

OpenStreetMap data is licensed under the **Open Database License (ODbL)**. Follow the relevant attribution and share-alike requirements for the data and any derived database. Review the terms of each additional map source or asset separately.

### Permissions and privacy

Abtin Maps is intended to respect user privacy. The developer's stated privacy policy is that the app does not store personal information, location history, travelled routes, camera images, GPS information, or other user data on a server or elsewhere outside the device. Information required for app features is intended to be processed locally on the device, and personal information is not intended to be sent to a server or third party for storage. Camera images are used only while the user is using the AR feature and are not intended to be stored on a server.

These statements describe the developer's declared policy; they are not an independent security audit. Actual data handling depends on the exact release build, enabled services, and third-party dependencies. Verify the release build and its network behavior before publication.

- **Camera:** Requested only for the camera-based augmented-reality (AR) feature.
- **Location (GPS):** Used to determine the user's current position, show it on the map, and provide navigation.
- **Free to use:** Abtin Maps is offered free of charge.

### OpenStreetMap data

Map data used by Abtin Maps is sourced from the OpenStreetMap project, a collaborative open mapping project. Abtin Maps is an independent application and is not affiliated with, sponsored by, or commercially connected to the OpenStreetMap Foundation. OpenStreetMap data is available under the Open Database License (ODbL); attribution and applicable license requirements must be respected. See https://www.openstreetmap.org/copyright.

### GLB 3D models and third-party assets

The app uses certain GLB-format 3D models for vehicle visuals and other graphical elements. The developer states that these files were obtained from sources offering models for free and were used in the project while retaining their original filenames. The models are not represented or sold as original works created by the developer, and the app does not sell or independently commercially distribute the 3D model files. Abtin Maps itself is free to use.

Free availability does not necessarily mean that every model permits every type of reuse. Each model's original license and attribution requirements should be checked. If a creator, rights holder, or original publisher has a concern about a model used in the app, please email **abtinmaps@gmail.com**. After receiving and reviewing a request, if ownership or a use restriction is substantiated, the relevant model will be removed or replaced with an asset whose use is permitted.

### Testing status

The repository's development notes identify several areas that need on-device verification, including offline/online map behavior, routing, AR camera behavior, and 3D rendering. Treat the app as a development build until those checks are complete.

Suggested release checklist:

- [ ] `flutter pub get` completes successfully.
- [ ] Static analysis and tests pass.
- [ ] App launches on supported Android devices.
- [ ] Location permission grant/deny flows work.
- [ ] Online map behavior is checked.
- [ ] Offline map download/import and persistence are checked.
- [ ] Offline search and route calculation are checked.
- [ ] One-way roads and turn instructions are validated.
- [ ] AR camera permission and orientation are checked.
- [ ] OpenStreetMap attribution and third-party asset licenses are verified.
- [ ] Release signing key is stored securely and is backed up.

### Security: release signing key

**Never publish a source archive containing a private signing key or its password.** The included release notes indicate that this source package contains signing credentials. Remove `android/Key-abtin.p12`, `android/key.properties`, and any plaintext secrets from public distributions and repository history. Store signing credentials in a secure secret manager (for example, CI secrets) and rotate the key if it has been exposed and rotation is feasible. Keep a protected backup of the signing key needed for future updates.

### Contributing and issues

Please include the following when reporting a bug:

- Device model and Android version
- App version/build
- Whether the issue occurs online, offline, or both
- Region/map package used
- Reproduction steps and screenshots/logs, with personal information removed

### License

No project-wide license is specified in this README. Unless a license file is added, do not assume that the application source is open for unrestricted reuse. OpenStreetMap data, libraries, fonts, icons, and 3D assets may each have separate license and attribution requirements. Add a `LICENSE` file and an asset-attribution document before distributing the source publicly.

---

## فارسی

### معرفی

**آبتین مپس (Abtin Maps)** یک پروژهٔ مسیریابی مبتنی بر **Flutter و Dart** است. نمایش نقشه با استفاده از **MapLibre** انجام می‌شود و ساختار برنامه برای استفاده از نقشه‌های آنلاین و داده‌های نقشهٔ ذخیره‌شده روی دستگاه طراحی شده است. کد پروژه شامل بخش‌هایی برای موقعیت‌یابی GPS، محاسبهٔ مسیر، مکان‌های ذخیره‌شده، تنظیم ظاهر نقشه و صفحهٔ دوربین واقعیت افزوده (AR) است.

عملکرد واقعی هر قابلیت به دادهٔ نقشهٔ نصب‌شده، دسترسی به اینترنت، مجوزهای دستگاه و آزمایش روی گوشی مقصد بستگی دارد.

### قابلیت‌های اصلی

- **نمایش نقشه:** نمایش نقشه با MapLibre و پشتیبانی از سبک‌های سفارشی.
- **داده‌های OpenStreetMap:** امکان استفاده از داده‌های مبتنی بر OpenStreetMap با رعایت انتساب منبع و مجوز مربوطه.
- **موقعیت‌یابی GPS:** دریافت موقعیت فعلی و هموارسازی حرکت نشانگر وسیلهٔ نقلیه.
- **مسیریابی:** کد درخواست مسیر آنلاین و موتور مسیریابی آفلاین در پروژه وجود دارد. کیفیت مسیریابی آفلاین به بستهٔ نقشه و گراف راه‌های آن وابسته است.
- **حالت‌های مسیر:** حالت‌های سریع‌ترین، کوتاه‌ترین و اقتصادی در کد پروژه پیاده‌سازی شده‌اند؛ پیش از اتکا به آن‌ها، عملکردشان را روی دستگاه واقعی آزمایش کنید.
- **مکان‌های ذخیره‌شده:** نگهداری محلی مکان‌ها و داده‌های مرتبط با مسیر.
- **نمایش سه‌بعدی:** پشتیبانی کد پروژه از مدل‌های GLB و سبک‌پردازی ساختمان‌های سه‌بعدی نقشه.
- **نمای دوربین AR:** صفحهٔ مسیریابی مبتنی بر دوربین در پروژه وجود دارد و برای آن مجوز دوربین لازم است.
- **چندزبانه بودن:** منابع فارسی و انگلیسی و ساختار بومی‌سازی رابط کاربری.
- **تنظیمات نقشه و مسیریابی:** تنظیم ظاهر نقشه و گزینه‌های مرتبط با ناوبری.

### فناوری‌های استفاده‌شده

- Flutter و Dart
- MapLibre GL
- Riverpod برای مدیریت وضعیت
- GoRouter برای جابه‌جایی بین صفحات
- SQLite و Drift برای داده‌های محلی
- Geolocator و permission_handler برای موقعیت مکانی و مجوزها
- افزونهٔ Camera برای نمای AR
- `model_viewer_plus` برای نمایش مدل‌های GLB

### پیش‌نیازهای بیلد

طبق فایل راهنمای بیلد پروژه، ابزارهای زیر مورد استفاده قرار گرفته‌اند:

- Flutter نسخهٔ پایدار 3.35.1
- Dart نسخهٔ 3.9.0
- Android SDK Platform 36
- Android NDK نسخهٔ 28.2.13676358
- Java / JDK 21

با تغییر پروژه ممکن است نسخه‌های سازگار نیز تغییر کنند.

### اجرا در محیط توسعه

1. Flutter و ابزارهای توسعهٔ Android را نصب کنید.
2. مخزن را دریافت و از حالت فشرده خارج کنید.
3. ترمینال را در ریشهٔ پروژه، یعنی پوشه‌ای که `pubspec.yaml` در آن قرار دارد، باز کنید.
4. وابستگی‌ها را دریافت کنید:

   ```bash
   flutter pub get
   ```

5. دستگاه‌های متصل را بررسی کنید:

   ```bash
   flutter devices
   ```

6. برنامه را اجرا کنید:

   ```bash
   flutter run
   ```

### ساخت نسخهٔ انتشار اندروید

برای ساخت APK:

```bash
flutter pub get
flutter build apk --release
```

برای ساخت Android App Bundle با پسوند AAB:

```bash
flutter build appbundle --release
```

مسیر معمول خروجی‌ها:

- APK: `build/app/outputs/flutter-apk/app-release.apk`
- AAB: `build/app/outputs/bundle/release/app-release.aab`

موفقیت بیلد به‌تنهایی به معنی عملکرد صحیح GPS، مسیریابی، نقشهٔ آفلاین، AR یا همهٔ صفحات نیست. خروجی را روی گوشی واقعی آزمایش کنید.

### نقشه‌ها و داده‌های آفلاین

قابل‌دسترس بودن نقشه به بسته‌های نقشه‌ای بستگی دارد که در برنامه قرار گرفته‌اند یا از طریق آن دریافت می‌شوند. وجود کد نمایش نقشهٔ محلی به‌تنهایی تضمین نمی‌کند که در هر نسخه، نقشهٔ آفلاین آماده‌ای همراه برنامه باشد.

پیش از انتشار، این موارد را بررسی کنید:

1. بستهٔ نقشهٔ منطقهٔ موردنظر در برنامه وجود دارد یا امکان دریافت آن فراهم است.
2. نقشه پس از نصب نمایش داده می‌شود و بدون اینترنت نیز در دسترس می‌ماند.
3. جست‌وجو و محاسبهٔ مسیر آفلاین برای منطقهٔ انتخابی کار می‌کند.
4. جهت حرکت در خیابان‌های یک‌طرفه، تقاطع‌ها، راهنمای گردش و اتصال موقعیت GPS به جاده صحیح است.
5. انتساب منبع OpenStreetMap در محل‌های لازم نمایش داده می‌شود.

داده‌های OpenStreetMap تحت مجوز **Open Database License (ODbL)** منتشر می‌شوند. الزامات انتساب منبع و اشتراک‌گذاری مشابه برای داده‌ها و پایگاه‌های مشتق‌شده را رعایت کنید. برای سایر منابع نقشه و فایل‌های جانبی نیز مجوز هر منبع را جداگانه بررسی کنید.

### مجوزها و حریم خصوصی

- **موقعیت مکانی:** برای نمایش موقعیت فعلی و مسیریابی استفاده می‌شود.
- **دوربین:** برای نمای واقعیت افزوده مبتنی بر دوربین استفاده می‌شود.
- **پایگاه داده و ذخیره‌سازی محلی:** کد پروژه بخش‌هایی برای نگهداری محلی اطلاعات برنامه دارد.

طبق سیاست اعلام‌شده از سوی سازنده، اطلاعات کاربر روی سرور راه دور ذخیره نمی‌شود. این ادعا باید با بررسی نسخهٔ نهایی و تمام سرویس‌های فعال تأیید شود. موقعیت مکانی داده‌ای حساس است؛ مجوز آن را فقط هنگام نیاز درخواست کنید و کاربردش را شفاف توضیح دهید. ادعای «هیچ داده‌ای جمع‌آوری نمی‌شود» تنها زمانی مطرح شود که همهٔ سرویس‌ها و وابستگی‌های نسخهٔ نهایی بررسی شده باشند.

### وضعیت توسعه و آزمایش

یادداشت‌های توسعهٔ پروژه، آزمایش روی دستگاه واقعی را برای بخش‌هایی از جمله عملکرد نقشهٔ آنلاین و آفلاین، مسیریابی، دوربین AR و نمایش سه‌بعدی ضروری می‌دانند. تا پایان این آزمایش‌ها، برنامه را نسخهٔ در حال توسعه در نظر بگیرید.

چک‌لیست پیشنهادی پیش از انتشار:

- [ ] اجرای موفق `flutter pub get`
- [ ] موفقیت تحلیل ایستا و تست‌ها
- [ ] اجرای برنامه روی دستگاه‌های اندرویدی هدف
- [ ] بررسی حالت‌های تأیید و رد مجوز موقعیت مکانی
- [ ] آزمایش نقشهٔ آنلاین
- [ ] آزمایش دریافت یا واردکردن نقشهٔ آفلاین و ماندگاری آن
- [ ] آزمایش جست‌وجو و محاسبهٔ مسیر آفلاین
- [ ] بررسی خیابان‌های یک‌طرفه و دستورهای گردش
- [ ] بررسی مجوز دوربین و چرخش تصویر در AR
- [ ] بررسی انتساب OpenStreetMap و مجوز فایل‌های جانبی
- [ ] نگهداری امن و پشتیبان‌گیری از کلید امضای انتشار

### هشدار امنیتی: کلید امضای برنامه

**فایل منبعی را که شامل کلید خصوصی امضا یا رمز آن است به‌صورت عمومی منتشر نکنید.** طبق یادداشت بیلد این پروژه، بستهٔ منبع شامل اطلاعات محرمانهٔ امضا است. فایل‌های `android/Key-abtin.p12` و `android/key.properties` و هر رمز متنی را از بسته‌های عمومی و تاریخچهٔ مخزن حذف کنید. اطلاعات امضا را در بخش امن متغیرها و Secrets سامانهٔ CI نگهداری کنید. اگر کلید افشا شده است، در صورت امکان‌پذیر بودن، دربارهٔ تعویض آن اقدام کنید. برای انتشار به‌روزرسانی‌های بعدی، نسخهٔ پشتیبان امن از کلید موردنیاز را نگه دارید.

### گزارش خطا و مشارکت

هنگام گزارش خطا، در صورت امکان این اطلاعات را ارائه کنید:

- مدل گوشی و نسخهٔ Android
- نسخه و شمارهٔ ساخت برنامه
- آنلاین یا آفلاین بودن هنگام بروز مشکل
- منطقه و بستهٔ نقشهٔ استفاده‌شده
- مراحل بازتولید خطا، تصویر صفحه یا گزارش فنی؛ بدون اطلاعات شخصی

### مجوز انتشار کد

در این README مجوز عمومی مشخصی برای کل کد پروژه اعلام نشده است. تا زمانی که فایل `LICENSE` اضافه نشده، استفادهٔ آزاد و نامحدود از کد را مفروض ندانید. داده‌های OpenStreetMap، کتابخانه‌ها، فونت‌ها، آیکون‌ها و مدل‌های سه‌بعدی ممکن است هرکدام شرایط مجوز و انتساب جداگانه داشته باشند. پیش از انتشار عمومی مخزن، فایل `LICENSE` و فهرست منابع و مجوز فایل‌های جانبی را اضافه کنید.

---

## App description | معرفی برنامه برای کاربران

### فارسی

# آبتین Maps | نقشه و مسیریابی آفلاین و آنلاین

آبتین Maps یک اپلیکیشن رایگان نقشه و مسیریابی است که با هدف ارائهٔ تجربه‌ای ساده، سریع و کاربردی برای مشاهدهٔ نقشه، پیدا کردن مکان‌ها و مسیریابی طراحی شده است. این برنامه از داده‌های OpenStreetMap استفاده می‌کند و برای کار با نقشه‌های آنلاین و نقشه‌های ذخیره‌شده روی دستگاه طراحی شده است. دسترس‌پذیری و کیفیت هر قابلیت به نسخهٔ برنامه، داده‌های نقشهٔ موجود و آزمایش روی دستگاه بستگی دارد.

**امکانات اصلی**

- نمایش نقشه بر پایهٔ داده‌های OpenStreetMap
- قابلیت‌های نمایش مسیر و مسیریابی، با وابستگی عملکرد به داده‌ها و نسخهٔ برنامه
- پشتیبانی کدنویسی‌شده از نقشه و مسیریابی آفلاین؛ پیش از اتکا به آن، عملکرد بستهٔ منطقه‌ای را بررسی کنید
- نمایش موقعیت فعلی کاربر با GPS
- قطب‌نما و نمایش جهت شمال، در صورت پشتیبانی دستگاه و نسخه
- نمایش سرعت لحظه‌ای خودرو، در صورت دسترسی به دادهٔ موقعیت
- ذخیرهٔ خانه، محل کار و مکان‌های موردعلاقه در قابلیت‌های پشتیبانی‌شدهٔ برنامه
- جست‌وجوی مکان‌ها و معابر، وابسته به منبع داده و وضعیت اتصال
- مدیریت نقشه‌های مناطق مختلف
- حالت شب برای راحتی بیشتر هنگام استفاده در محیط کم‌نور
- نمایش خودرو با مدل سه‌بعدی GLB
- رابط کاربری با سبک شیشه‌ای (Glass)
- منابع رابط کاربری چندزبانه
- نمای دوربین واقعیت افزوده (AR) در بخش مربوطه

**مجوزهای برنامه**

- **دوربین:** فقط برای استفاده از قابلیت واقعیت افزوده (AR) درخواست می‌شود.
- **موقعیت مکانی (GPS):** برای تشخیص موقعیت فعلی، نمایش آن روی نقشه و ارائهٔ قابلیت‌های مسیریابی استفاده می‌شود.

**حریم خصوصی**

طبق سیاست اعلام‌شدهٔ سازنده، آبتین Maps اطلاعات شخصی، موقعیت مکانی، مسیرهای طی‌شده، تصاویر دوربین یا اطلاعات GPS کاربران را روی سرور ذخیره نمی‌کند و اطلاعات شخصی را برای ذخیره‌سازی به سرور یا شخص ثالث ارسال نمی‌کند. پردازش موردنیاز قابلیت‌ها برای استفادهٔ برنامه روی دستگاه انجام می‌شود و تصاویر دوربین صرفاً هنگام استفاده از قابلیت AR به کار می‌روند. این توضیحات بیانگر سیاست اعلام‌شدهٔ سازنده هستند؛ رفتار نسخهٔ نهایی و وابستگی‌های آن باید پیش از انتشار نیز بررسی شود.

**منبع نقشه**

داده‌های نقشه از پروژهٔ مشارکتی OpenStreetMap تهیه می‌شوند. آبتین Maps برنامه‌ای مستقل است و وابستگی یا وابستگی تجاری مستقیمی به OpenStreetMap Foundation ندارد. اطلاعات مجوز و انتساب: https://www.openstreetmap.org/copyright

**مدل‌های سه‌بعدی GLB**

برخی مدل‌های سه‌بعدی از منابعی دریافت شده‌اند که آن‌ها را رایگان ارائه می‌کنند و نام فایل‌های اصلی حفظ شده است. این مدل‌ها به‌عنوان آثار تولیدشده توسط سازندهٔ آبتین Maps معرفی یا فروخته نمی‌شوند و برنامه برای استفاده از خود اپلیکیشن هزینه‌ای دریافت نمی‌کند. رایگان بودن دانلود یک مدل لزوماً به معنی مجاز بودن همهٔ انواع استفاده نیست؛ شرایط مجوز هر مدل باید جداگانه بررسی شود.

اگر سازنده، صاحب حقوق یا منتشرکنندهٔ اصلی مدلی دربارهٔ استفاده از آن در برنامه مشکلی دارد، از طریق ایمیل زیر اطلاع دهد. پس از دریافت و بررسی درخواست و در صورت تأیید مالکیت یا محدودیت استفاده، مدل موردنظر حذف یا با مدلی دارای مجوز مناسب جایگزین می‌شود.

**ارتباط با سازنده:** abtinmaps@gmail.com

---

### English

# Abtin Maps | Online and Offline Maps & Navigation

Abtin Maps is a free map and navigation application designed to provide a simple, fast, and practical way to view maps, find places, and navigate. It uses OpenStreetMap data and is designed to work with online maps as well as map data stored on the device. Feature availability and quality depend on the app version, available map data, and testing on the target device.

**Main features**

- Map display based on OpenStreetMap data
- Route display and navigation features, subject to the available data and app version
- Code support for offline maps and offline routing; verify the regional map package before relying on it
- Current-location display using GPS
- Compass and north-direction indicator where supported by the device and app version
- Vehicle speed display when location data is available
- Saving Home, Work, and favorite places in supported app features
- Place and street search, depending on the data source and connection state
- Management of maps for different regions
- Night mode for more comfortable use in low-light conditions
- 3D vehicle visuals using GLB models
- Glass-style user interface
- Multilingual interface resources
- Camera-based augmented reality (AR) view

**App permissions**

- **Camera:** R
