# Abtin Maps | آبتین مپس

<p align="center">
  <strong>Offline Navigation. Smarter Journeys.</strong>
  <br/>
  <strong>مسیریابی هوشمند، مستقل از اینترنت</strong>
</p>

<p align="center">
  <em>A modern offline-first navigation platform built for reliable, intelligent, and seamless journeys.</em>
</p>

---

## 🇮🇷 فارسی

### درباره آبتین مپس

**آبتین مپس (Abtin Maps)** یک پروژه مسیریابی و ناوبری نسل جدید است که با تمرکز بر نقشه‌های آفلاین، مسیریابی هوشمند و تجربه کاربری روان توسعه داده می‌شود.

هدف آبتین مپس فراهم‌کردن تجربه‌ای قابل‌اعتماد از ناوبری است؛ تجربه‌ای که برای استفاده روزمره، سفرهای بین‌شهری و مسیرهای طولانی به اتصال دائمی اینترنت وابسته نباشد.

معماری پروژه به‌گونه‌ای طراحی شده است که داده‌های نقشه، اطلاعات جست‌وجو و نقاط موردعلاقه و داده‌های موردنیاز مسیریابی بتوانند به‌صورت محلی مدیریت و پردازش شوند.

### قابلیت‌ها و اهداف اصلی

- **نقشه‌های آفلاین:** امکان استفاده از داده‌های نقشه ذخیره‌شده روی دستگاه، بدون وابستگی دائمی به سرویس نقشه آنلاین.
- **مسیریابی آفلاین:** طراحی موتور مسیریابی برای محاسبه مسیرهای شهری و بین‌شهری با استفاده از داده‌های محلی.
- **جست‌وجوی مکان‌ها:** معماری جست‌وجوی محلی برای دسترسی به اطلاعات مکان‌ها، خیابان‌ها و نقاط موردعلاقه.
- **اطلاعات مسیر:** پشتیبانی معماری نقشه از اطلاعاتی مانند محدودیت‌های جاده‌ای، جهت حرکت، سرعت مجاز و سایر مشخصات مسیر، متناسب با داده‌های موجود.
- **مدیریت نقشه‌ها:** ساختار بسته‌های نقشه اختصاصی ABM با قابلیت توسعه برای پوشش مناطق مختلف.
- **نمایش نقشه:** توسعه سیستم نمایش نقشه با هدف ارائه تجربه‌ای روان، دقیق و خوانا در سطوح مختلف بزرگ‌نمایی.
- **نمایش سه‌بعدی خودرو:** توسعه نمایشگر سه‌بعدی مبتنی بر Filament برای نمایش مدل خودرو در محیط ناوبری.
- **راهنمای صوتی:** طراحی راهنمای صوتی مسیر با تمرکز بر اعلان‌های ضروری و جلوگیری از تکرار پیام‌های غیرضروری.
- **رابط کاربری چندزبانه:** پشتیبانی از توسعه رابط کاربری فارسی و انگلیسی و معماری قابل گسترش برای زبان‌های دیگر.

### فناوری‌ها

| فناوری | کاربرد |
|---|---|
| Flutter / Dart | توسعه رابط کاربری و منطق اصلی اپلیکیشن |
| Android Native | یکپارچه‌سازی قابلیت‌های بومی اندروید |
| Filament | رندرینگ سه‌بعدی مدل خودرو |
| SQLite | ذخیره‌سازی و بازیابی داده‌های مکانی |
| ABM | قالب اختصاصی بسته‌بندی داده‌های نقشه |
| MBTiles | نگهداری داده‌های کاشی نقشه در معماری فعلی |
| GitHub Actions | خودکارسازی فرایندهای ساخت و انتشار |

### معماری داده‌های نقشه

آبتین مپس از قالب اختصاصی **ABM** برای بسته‌بندی داده‌های نقشه استفاده می‌کند.

در معماری فعلی، داده‌های استخراج‌شده از بسته نقشه در دو بخش اصلی مدیریت می‌شوند:

- `map.mbtile` — داده‌های کاشی موردنیاز برای نمایش نقشه.
- `map.sqlite` — داده‌های ساختاریافته موردنیاز برای جست‌وجو، مکان‌ها و اطلاعات مسیریابی.

این تفکیک با هدف کاهش مصرف حافظه، دسترسی سریع‌تر به اطلاعات و جلوگیری از بارگذاری غیرضروری کل پایگاه داده در حافظه طراحی شده است.

### وضعیت توسعه

آبتین مپس یک پروژه در حال توسعه است. قابلیت‌ها و اجزای مختلف آن به‌صورت مرحله‌ای پیاده‌سازی، آزمایش و بهینه‌سازی می‌شوند.

وضعیت هر قابلیت ممکن است با انتشار نسخه‌های جدید تغییر کند. بنابراین توضیحات این README بیانگر جهت‌گیری و معماری پروژه هستند و لزوماً به معنی تکمیل تمام قابلیت‌ها در نسخه فعلی نیستند.

### مشارکت در توسعه

مشارکت توسعه‌دهندگان، گزارش دقیق خطاها و ارائه پیشنهادهای فنی می‌تواند به بهبود پروژه کمک کند.

برای مشارکت:

1. مخزن را Fork کنید.
2. یک Branch مستقل برای تغییرات خود بسازید.
3. تغییرات را با توضیح فنی روشن ثبت کنید.
4. یک Pull Request ارسال کنید.

در گزارش خطا، نسخه اپلیکیشن، نسخه سیستم‌عامل، مراحل بازتولید مشکل و گزارش‌های مرتبط را درج کنید.

---

## 🇬🇧 English

### About Abtin Maps

**Abtin Maps** is a next-generation navigation project focused on offline maps, intelligent routing, and a smooth, reliable navigation experience.

The project aims to make everyday navigation and long-distance travel less dependent on continuous internet connectivity.

Its architecture is designed to manage map content, search data, points of interest, and routing information locally, enabling navigation components to operate using data stored on the device.

### Core Features & Development Goals

- **Offline Maps:** Access locally stored map data without continuous reliance on online map services.
- **Offline Routing:** Development of a routing engine designed to calculate urban and intercity routes using locally available data.
- **Place Search:** A local search architecture for discovering locations, streets, and points of interest.
- **Road Information:** Support for road attributes such as one-way restrictions, speed limits, road restrictions, and other routing-related information, subject to available map data.
- **Map Management:** A dedicated ABM map-package structure designed to support different geographic regions.
- **Map Rendering:** Development of a smooth and detailed map-rendering system across different zoom levels.
- **3D Vehicle Visualization:** A Filament-based 3D rendering system for displaying vehicle models within the navigation environment.
- **Voice Guidance:** Route guidance designed to prioritize relevant navigation instructions and minimize unnecessary repetition.
- **Multilingual Interface:** Persian and English interface support, with an architecture designed for additional languages.

### Technology Stack

| Technology | Purpose |
|---|---|
| Flutter / Dart | Application UI and core application logic |
| Android Native | Native Android integration |
| Filament | Real-time 3D vehicle rendering |
| SQLite | Local geospatial data storage and queries |
| ABM | Dedicated map data packaging format |
| MBTiles | Map tile storage in the current architecture |
| GitHub Actions | Automated build and release workflows |

### Map Data Architecture

Abtin Maps uses its dedicated **ABM** format to package offline map data.

The current extraction architecture separates the map data into two primary components:

- `map.mbtile` — Stores map tile data used by the rendering system.
- `map.sqlite` — Stores structured data used for search, places, and routing-related operations.

This separation is intended to improve data access efficiency, reduce unnecessary memory usage, and avoid loading the entire database into memory.

### Development Status

Abtin Maps is an actively evolving project.

Its components are being implemented, tested, and optimized incrementally. Feature availability may vary between development stages and releases.

The features described in this document represent the project's architecture and development direction; they should not be interpreted as a guarantee that every feature is fully implemented in the current release.

### Contributing

Contributions from developers, technical feedback, and well-documented bug reports are welcome.

To contribute:

1. Fork the repository.
2. Create a dedicated branch for your changes.
3. Commit your changes with clear technical descriptions.
4. Submit a Pull Request.

When reporting an issue, include the application version, operating system version, reproduction steps, and relevant logs whenever possible.

---

## Project Repository

**Abtin Maps — Offline Navigation Platform**

Repository: https://github.com/abtin123/project

---

<p align="center">
  <strong>Abtin Maps</strong>
  <br/>
  <em>Navigate with confidence. Even offline.</em>
  <br/>
  <em>با اطمینان مسیریابی کن؛ حتی بدون اینترنت.</em>
</p>
