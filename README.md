# Abtin Maps

پروژهٔ Flutter برای ساخت Android و iOS. راهنمای کامل build در [`BUILDING_RELEASE.txt`](BUILDING_RELEASE.txt) آمده است.

## پیش‌نیازها

- Flutter 3.35.1 stable و Dart 3.9
- Android: JDK 21، Android SDK 36 و NDK `28.2.13676358`
- iOS: macOS، Xcode و CocoaPods

## Android

```sh
flutter pub get
flutter build apk --release
```

نسخهٔ Release این بسته عمداً **بدون امضا** ساخته می‌شود و keystore خصوصی در سورس قرار ندارد. برای انتشار عمومی، مالک برنامه باید با کلید خودش محلی امضا کند.

## iOS

روی Mac:

```sh
flutter pub get
cd ios && pod install && cd ..
flutter build ipa --release
```

ساخت و امضای IPA انتشار به Xcode و گواهی/Provisioning Profile اپل در Mac نیاز دارد. هیچ گواهی یا اطلاعات امضایی در این پروژه نگهداری نمی‌شود.

## ساخت هم‌زمان در GitHub

پوشهٔ `.github/workflows` را همراه سورس به مخزن GitHub بفرستید. با push به
`main`/`master`، pull request یا اجرای دستی `Build Android and iOS` از تب Actions،
دو job مستقل هم‌زمان اجرا می‌شوند. خروجی‌ها را از همان اجرای workflow با نام‌های
`android-release-unsigned` (APK و AAB) و `ios-ipa-unsigned` (IPA در یک artifact فشرده)
دانلود کنید. IPA پیش‌فرض بدون امضای Apple است و تا زمان امضای معتبر برای نصب روی
دستگاه یا انتشار در App Store قابل استفاده نیست.
