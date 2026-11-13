# Abtin Maps — ABM Builder

[فارسی](#فارسی) · [English](#english)

---

## English

The ABM builder turns OpenStreetMap data (`.osm.pbf`) into **`.abm` map archives** for the Abtin Maps app. Each archive contains vector tiles (MBTiles), a SQLite database (`map.sqlite`: names, categories, POIs, places), a search index, and a routing graph. A GitHub Actions workflow builds the archives and publishes them, together with `manifest.json`, to the `maps-v4` release. The app reads that manifest to list, download and update maps.

### Repository layout

| Path | Purpose |
|---|---|
| `build_abm.py` | Main CLI: builds an ABM for a country or its regions |
| `extractors/` | OSM → features (roads, buildings, water, places, **POIs**, boundaries) |
| `abm_builder/` | Tile (MBTiles/MVT) and ABM v2 schema generation |
| `routing/` | Routing graph builder, turn restrictions |
| `search/` | Search database and Persian text normalisation |
| `release_packaging/` | ABM packaging, verification, patches, release manifest |
| `countries.json` | Supported countries and their Geofabrik PBF URLs |
| `sample/regions/` | Province/state definitions (`IR.json`, `US.json`) |
| `.github/workflows/Builde-map.yml` | Build + publish pipeline |
| `tests/` | pytest suite |

### Local build

```bash
pip install -r requirements.txt        # osmium, shapely, pytest

# Build Iran, one ABM per province
python build_abm.py iran-latest.osm.pbf -o dist --country IR \
    --regions sample/regions/IR.json

# Only some provinces
python build_abm.py iran-latest.osm.pbf -o dist --country IR \
    --regions sample/regions/IR.json --only-regions IR-ESF,IR-KER

# Run the tests
pytest
```

Run `python build_abm.py --help` for all options.

### Publishing (GitHub Actions)

1. Push your changes to the repository.
2. Open **Actions → ABM Map Builder → Run workflow**.
3. Set `country` (e.g. `IR`, or `IR,AM`, or `all`), keep `publish = true`.
   Use `force` to rebuild even if nothing changed, or `regions` to rebuild specific provinces.
4. A scheduled run happens every Monday at 03:00 UTC for the countries in the `WEEKLY_COUNTRIES` variable (default `IR`).

**When is a region rebuilt?** A region is rebuilt when its source PBF changed **or** the *builder hash* changed. The builder hash covers `build_abm.py`, `abm_builder/`, `extractors/`, `routing/`, `search/`, `release_packaging/create_abm.py` and `tools/`. So any change to the builder code triggers a rebuild automatically, without `force`.

### How the app detects updates

The app compares the SHA-256 of the installed `.abm` with the `sha256` in `manifest.json`. If they differ, an update is offered. If a binary patch is available and smaller than 90% of the full file, only the patch is downloaded.

### POI categories

`extractors/osm.py → pois()` writes the OSM tag value into the `categories` table. The app maps that value to an icon and filter class.

| OSM tag | Category | App icon |
|---|---|---|
| `amenity=fuel` | `fuel` | Fuel station |
| `shop=fuel` (charcoal, firewood, kerosene, bottled gas) | `shop_fuel` | Shop (supermarket icon) |
| `shop=supermarket / mall / convenience` | same value | Shop |

`shop=fuel` is a *shop*, not a vehicle fuel station, so it must **not** become `fuel`. Only `amenity=fuel` does.

**Adding a new POI category** requires changes in three places:
1. `extractors/osm.py` — emit the category.
2. App style `assets/styles/abtin_unified_style.json` — add it to the `icon-image` match in the POI layers.
3. App `_offlinePoiClassesByKlass` (`online_map_view.dart`) — map it to a POI class.

Then rebuild and publish the maps.

### Data license

Map data © OpenStreetMap contributors, ODbL 1.0 — <https://www.openstreetmap.org/copyright>.

---

<div dir="rtl">

## فارسی

بیلدر ABM داده‌های OpenStreetMap (فایل `.osm.pbf`) را به **آرشیوهای `.abm`** برای اپ آبتین مپ تبدیل می‌کند. هر آرشیو شامل تایل‌های برداری (MBTiles)، پایگاه‌داده‌ی SQLite (`map.sqlite`: نام‌ها، دسته‌ها، POIها و مکان‌ها)، ایندکس جستجو و گراف مسیریابی است. یک workflow در GitHub Actions آرشیوها را می‌سازد و همراه با `manifest.json` در ریلیز `maps-v4` منتشر می‌کند. اپ از این manifest برای نمایش، دانلود و به‌روزرسانی نقشه‌ها استفاده می‌کند.

### ساختار ریپو

| مسیر | کاربرد |
|---|---|
| `build_abm.py` | اسکریپت اصلی ساخت ABM برای یک کشور یا استان‌هایش |
| `extractors/` | استخراج داده از OSM (جاده، ساختمان، آب، مکان‌ها، **POI**، مرزها) |
| `abm_builder/` | تولید تایل (MBTiles/MVT) و اسکیمای ABM v2 |
| `routing/` | ساخت گراف مسیریابی و محدودیت‌های گردش |
| `search/` | پایگاه جستجو و نرمال‌سازی متن فارسی |
| `release_packaging/` | بسته‌بندی و اعتبارسنجی ABM، پچ و manifest ریلیز |
| `countries.json` | کشورهای پشتیبانی‌شده و آدرس PBF آن‌ها (Geofabrik) |
| `sample/regions/` | تعریف استان‌ها/ایالت‌ها (`IR.json` و `US.json`) |
| `.github/workflows/Builde-map.yml` | خط لوله‌ی ساخت و انتشار |
| `tests/` | تست‌های pytest |

### ساخت محلی

```bash
pip install -r requirements.txt        # osmium, shapely, pytest

# ساخت ایران، هر استان یک ABM
python build_abm.py iran-latest.osm.pbf -o dist --country IR \
    --regions sample/regions/IR.json

# فقط چند استان
python build_abm.py iran-latest.osm.pbf -o dist --country IR \
    --regions sample/regions/IR.json --only-regions IR-ESF,IR-KER

# اجرای تست‌ها
pytest
```

برای دیدن همه‌ی گزینه‌ها `python build_abm.py --help` را اجرا کنید.

### انتشار (GitHub Actions)

۱. تغییرات را در ریپو push کنید.
۲. به **Actions ← ABM Map Builder ← Run workflow** بروید.
۳. مقدار `country` را بدهید (مثلاً `IR` یا `IR,AM` یا `all`) و `publish` را روی true بگذارید.
   برای ساخت دوباره حتی بدون تغییر از `force` و برای استان‌های مشخص از `regions` استفاده کنید.
۴. هر دوشنبه ساعت ۰۳:۰۰ UTC یک اجرای زمان‌بندی‌شده برای کشورهای متغیر `WEEKLY_COUNTRIES` (پیش‌فرض `IR`) انجام می‌شود.

**چه زمانی یک منطقه دوباره ساخته می‌شود؟** وقتی فایل PBF منبع تغییر کرده باشد **یا** *هش بیلدر* عوض شده باشد. هش بیلدر شامل `build_abm.py`، `abm_builder/`، `extractors/`، `routing/`، `search/`، `release_packaging/create_abm.py` و `tools/` است. پس هر تغییری در کد بیلدر خودکار باعث ساخت دوباره می‌شود و نیازی به `force` نیست.

### اپ چطور آپدیت را تشخیص می‌دهد

اپ هش SHA-256 فایل `.abm` نصب‌شده را با مقدار `sha256` در `manifest.json` مقایسه می‌کند. اگر فرق داشته باشد، آپدیت پیشنهاد می‌شود. اگر پچ باینری موجود و کوچک‌تر از ۹۰٪ حجم فایل کامل باشد، فقط پچ دانلود می‌شود.

### دسته‌های POI

تابع `pois()` در `extractors/osm.py` مقدار تگ OSM را در جدول `categories` می‌نویسد و اپ آن مقدار را به آیکن و کلاس فیلتر نگاشت می‌کند.

| تگ OSM | دسته | آیکن در اپ |
|---|---|---|
| `amenity=fuel` | `fuel` | جایگاه سوخت |
| `shop=fuel` (زغال، هیزم، نفت، کپسول گاز) | `shop_fuel` | فروشگاه (آیکن سوپرمارکت) |
| `shop=supermarket / mall / convenience` | همان مقدار | فروشگاه |

`shop=fuel` یک **فروشگاه** است، نه جایگاه سوخت خودرو، پس نباید `fuel` شود. فقط `amenity=fuel` جایگاه سوخت است.

**افزودن دسته‌ی POI جدید** در سه جا تغییر لازم دارد:
۱. `extractors/osm.py` — تولید دسته.
۲. استایل اپ `assets/styles/abtin_unified_style.json` — افزودن آن به `icon-image` در لایه‌های POI.
۳. `_offlinePoiClassesByKlass` در `online_map_view.dart` — نگاشت آن به یک کلاس POI.

بعد نقشه‌ها را دوباره بسازید و منتشر کنید.

### مجوز داده

داده‌های نقشه © مشارکت‌کنندگان OpenStreetMap، مجوز ODbL 1.0 — <https://www.openstreetmap.org/copyright>.

</div>
