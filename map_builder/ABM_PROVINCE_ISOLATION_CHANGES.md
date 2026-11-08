# ABM Builder — Province Isolation / Incremental Updates

## Implemented
- Per-province SQLite: `<ID>.sqlite`.
- Per-province MBTiles: `<ID>.mbtiles`.
- Internal ABM manifest records `id`, `database`, `tiles`, per-file SHA-256 hashes and sizes.
- Metadata is ABM v7 and explicitly records the package id and runtime store filenames.
- Build workspaces use a unique temp directory per build id, preventing concurrent province jobs from sharing staging files.
- `build_abm.py --only-regions IR-ESF,IR-KER` builds only requested configured provinces.
- Weekly workflow fingerprints each configured region independently after source download and rebuilds only regions whose source fingerprint or builder fingerprint changed.
- Manual `workflow_dispatch` now accepts an optional `regions` input such as `IR-ESF,IR-KER`; selected regions are forced through the build path without rebuilding unrelated regions.
- Release preparation and chunk patching remain per province; unchanged provinces are carried forward from the previous release manifest.
- `builder_hash` is retained in release source metadata so builder changes are detected correctly.
- Regional source fingerprints are stored as `region_pbf_sha256` in each province's source metadata.
- Existing routing/search/POI data and graph construction are not removed.

## Builder files changed
- `build_abm.py`
- `release_packaging/create_abm.py`
- `release_packaging/create_abm.py`
- `release_packaging/build_release_manifest.py`
- `release_packaging/check_source.py`
- `release_packaging/check_region_source.py` (new)
- `.github/workflows/Builde-map.yml`
- `tests/test_pipeline.py`
- `tests/test_province_package_isolation.py` (new)

## Tests actually executed
- `python3 -m pytest -q` → **32 passed, 1 skipped**.
- End-to-end sample regional build of two packages → **success**.
- Package inspection confirmed each ABM contains only its own `<ID>.sqlite` and `<ID>.mbtiles`, plus `manifest.json` and `metadata.json`.
- Parallel isolated sample builds → **success**.
- `--only-regions` build selection → **success**.
- Workflow YAML parse → **success**.
- Python syntax compilation → **success**.

## Not executed
- Real GitHub Actions run against live OSM/Geofabrik data: not available in this environment.
- `check_region_source.py` against a real PBF: the environment lacks the `osmium` Python package and has no network access to install it.
- Flutter analyzer/build and Android/device tests: Flutter/Dart SDK is not installed in this environment.

## Fix (verification pass, 2026-09-30)
- Removed duplicate `packaging/` dir (PyPI name collision). Workflow `Builde-map.yml` still called `packaging/...` and `from packaging.check_source`, while `build_abm.py` used `release_packaging/`; `release_packaging/check_source.py` lacked `--region-fingerprints` and `check_region_source.py` was missing. All merged into `release_packaging/`; workflow and test import updated.
