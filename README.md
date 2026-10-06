# 🗺️ آبتین مپس | Abtin Maps

**آبتین مپس** یک اپلیکیشن مسیریابی هوشمند برای Android است که با تمرکز بر مسیریابی آفلاین، نقشه‌های سه‌بعدی، GPS، جست‌وجوی مکان‌ها و تجربه کاربری فارسی توسعه داده شده است.

**Abtin Maps** is a smart Android navigation application focused on offline navigation, 3D maps, GPS, place search, and a Persian-first user experience.

---

## ✨ امکانات | Features

### 🇮🇷 فارسی

- 🗺️ نقشه آفلاین و آنلاین
- 🧭 مسیریابی آفلاین
- 🚗 نمایش خودرو و حرکت روی مسیر
- 🏙️ نمایش ساختمان‌های سه‌بعدی
- 📍 موقعیت‌یابی GPS
- 🔎 جست‌وجوی مکان‌ها و POI
- ⭐ مکان‌های ذخیره‌شده و علاقه‌مندی‌ها
- 🚨 هشدارهای جاده‌ای
- 🎙️ راهنمای صوتی مسیر
- 📷 حالت مسیریابی AR
- 🌐 پشتیبانی فارسی و انگلیسی
- 🔗 Deep Link برای مسیرها
- 📤 اشتراک‌گذاری مکان
- 🌙 رابط کاربری Dark
- 📱 سازگار با Android

### 🇬🇧 English

- 🗺️ Online and offline maps
- 🧭 Offline navigation
- 🚗 Real-time vehicle and route display
- 🏙️ 3D buildings
- 📍 GPS positioning
- 🔎 Place and POI search
- ⭐ Saved places and favorites
- 🚨 Road alerts
- 🎙️ Voice navigation
- 📷 AR navigation mode
- 🌐 Persian and English support
- 🔗 Navigation Deep Links
- 📤 Location sharing
- 🌙 Dark UI
- 📱 Android support

---

## 🛠️ تکنولوژی | Technology

### فارسی

این پروژه با **Flutter و Dart** توسعه داده شده و برای Android طراحی شده است.

### English

The project is built with **Flutter and Dart** and designed for Android.

### Core Technologies

- Flutter
- Dart
- Android
- Kotlin
- SQLite / Drift
- MapLibre
- Riverpod

### مهم‌ترین پکیج‌ها | Main Packages

- `flutter_riverpod`
- `go_router`
- `drift`
- `sqlite3`
- `geolocator`
- `permission_handler`
- `maplibre_gl`
- `camera`
- `sensors_plus`
- `model_viewer_plus`
- `http`
- `flutter_svg`
- `app_links`
- `just_audio`
- `share_plus`

---

## 📋 پیش‌نیازها | Requirements

### فارسی

برای Build نسخه فعلی پیشنهاد می‌شود از موارد زیر استفاده کنید:

- Flutter `3.35.1` Stable
- Dart `3.9.0`
- Android SDK Platform `36`
- Android NDK `28.2.13676358`
- Java / JDK `21`

### English

Recommended environment for the current version:

- Flutter `3.35.1` Stable
- Dart `3.9.0`
- Android SDK Platform `36`
- Android NDK `28.2.13676358`
- Java / JDK `21`

---

## 🚀 اجرای پروژه | Getting Started

### فارسی

Repository را Clone کنید:

```bash
git clone https://github.com/YOUR_USERNAME/abtin-maps.git
cd abtin-maps
```

وابستگی‌ها را نصب کنید:

```bash
flutter pub get
```

اجرای نسخه Debug:

```bash
flutter run
```

### English

Clone the repository:

```bash
git clone https://github.com/YOUR_USERNAME/abtin-maps.git
cd abtin-maps
```

Install dependencies:

```bash
flutter pub get
```

Run the application:

```bash
flutter run
```

---

## 📦 ساخت نسخه Release | Release Build

### APK

```bash
flutter build apk --release
```

Output:

```text
build/app/outputs/flutter-apk/app-release.apk
```

### Android App Bundle

```bash
flutter build appbundle --release
```

Output:

```text
build/app/outputs/bundle/release/app-release.aab
```

---

## 🔐 امضای نسخه Release | Release Signing

### فارسی

اطلاعات KeyStore و رمزهای آن **نباید در GitHub قرار بگیرند**.

پروژه از `android/key.properties` یا Environment Variables برای Release Signing استفاده می‌کند.

نمونه `android/key.properties`:

```properties
storeFile=YOUR_KEYSTORE_FILE
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
storeType=PKCS12
```

این فایل را Commit نکنید.

### English

Keystore files, passwords, aliases, and signing secrets **must not be committed to GitHub**.

The project supports `android/key.properties` or environment variables for release signing.

Example:

```properties
storeFile=YOUR_KEYSTORE_FILE
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
storeType=PKCS12
```

Do not commit this file.

### Environment Variables

```text
ABTIN_KEYSTORE_PATH
ABTIN_KEYSTORE_PASSWORD
ABTIN_KEYSTORE_ALIAS
ABTIN_KEYSTORE_KEY_PASSWORD
ABTIN_KEYSTORE_TYPE
```

---

## ⚠️ امنیت | Security

### فارسی

فایل‌های زیر نباید در Repository عمومی قرار بگیرند:

```text
android/key.properties
android/*.jks
android/*.keystore
android/*.p12
android/*.pfx
```

همچنین هیچ Password، API Key یا Secret را داخل Source Code قرار ندهید.

### English

The following files must never be committed to a public repository:

```text
android/key.properties
android/*.jks
android/*.keystore
android/*.p12
android/*.pfx
```

Never store passwords, API keys, or other secrets directly in the source code.

---

## 🗺️ سیستم نقشه | Map System

### فارسی

سیستم ساخت و پردازش نقشه از اپلیکیشن اصلی جدا است.

**Map Builder** مسئول آماده‌سازی داده‌های نقشه، Vector Tiles، اطلاعات POI و Routing Graph است و خروجی آن توسط اپلیکیشن استفاده می‌شود.

داده‌های نقشه بر پایه **OpenStreetMap** هستند.

### English

The map processing pipeline is separate from the main application.

The **Map Builder** is responsible for preparing map data, vector tiles, POIs, and routing graphs. The resulting map data is then consumed by the application.

Map data is based on **OpenStreetMap**.

---

## 🌍 OpenStreetMap Attribution

This project uses data from OpenStreetMap.

https://www.openstreetmap.org/copyright

---

## 📱 Application ID

```text
ir.abtin.abtin_maps
```

---

## 🧪 وضعیت پروژه | Project Status

### فارسی

پروژه در حال توسعه است و برخی قابلیت‌ها همچنان در حال بهینه‌سازی و تست هستند.

مواردی مانند Offline Routing، GPS، AR Navigation، Voice Navigation و داده‌های نقشه باید روی دستگاه واقعی تست شوند.

### English

The project is actively under development.

Some features are still being optimized and tested, including Offline Routing, GPS, AR Navigation, Voice Navigation, and offline map data.

---

## 📝 مسیر توسعه | Roadmap

- [ ] بهینه‌سازی Offline Routing
- [ ] بهبود AR Navigation
- [ ] بهینه‌سازی Voice Navigation
- [ ] بهبود داده‌های Offline Maps
- [ ] تست کامل GPS
- [ ] بهینه‌سازی عملکرد نقشه
- [ ] بهبود POI Search
- [ ] انتشار نسخه‌های پایدار

---

## 🤝 مشارکت | Contributing

### فارسی

برای گزارش Bug، پیشنهاد قابلیت یا ارسال Pull Request خوشحال می‌شویم.

لطفاً هنگام گزارش مشکل، در صورت امکان موارد زیر را ارسال کنید:

- مدل دستگاه
- نسخه Android
- نسخه Abtin Maps
- مراحل بازتولید مشکل
- Screenshot یا Log

### English

Contributions, bug reports, feature requests, and pull requests are welcome.

When reporting a bug, please include:

- Device model
- Android version
- Abtin Maps version
- Steps to reproduce
- Screenshot or log, if available

---

## 📄 License

The project license has not been defined yet.

Until an official license is added, the source code should not be redistributed, modified for commercial use, or republished without permission from the project owner.

---

## ❤️ آبتین مپس | Abtin Maps

ساخته‌شده با ❤️ برای تجربه بهتر مسیریابی فارسی.

Built with ❤️ for a better Persian navigation experience.
