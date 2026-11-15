# Filament 3D vehicle renderer

The vehicle uses Google's native Filament renderer on both mobile platforms:

- **Android:** Kotlin implementation in `android/app/src/main/kotlin/ir/abtin/abtinmaps/FilamentCar.kt`, backed by Filament `1.56.0` and `gltfio-android`. All Filament / gltfio API calls are serialized on Android's main thread as required by `ResourceLoader`; texture decoding uses `asyncBeginLoad` / `asyncUpdateLoad` so it does not synchronously decode the whole model on the UI thread.
- **iOS:** Objective-C++ / C++ implementation in `ios/Runner/FilamentCarPlugin.mm`, backed by the official `Filament` CocoaPod `1.56.0` and Metal (`CAMetalLayer`). It uses Filament's version-matched built-in gltfio ubershader archive; the JIT provider is intentionally not referenced because the iOS pod exposes `gltfio_core`. GLB texture decoding is asynchronous, and a procedural studio cubemap provides metallic reflections and ambient light.
- **Flutter bridge:** `lib/features/vehicle/presentation/car_marker.dart` uses a Flutter texture on Android and a native `UiKitView` on iOS. Both receive the same bundled GLB paths, orbit angles, and model-change commands.
- **Models:** `assets/models/*.glb`, selected in `lib/features/vehicle/presentation/vehicle_provider.dart`.

The iOS implementation is registered by `AppDelegate.swift`; its Objective-C interface is exposed through `Runner-Bridging-Header.h`. Run `flutter pub get`, then `cd ios && pod install` on macOS before building iOS. Filament 1.56.0's official iOS podspec excludes Apple-silicon simulator arm64; use a physical iPhone/iPad target or a supported simulator architecture for that pinned runtime.

Rendering is demand-driven: Android submits a frame only after model, viewport, or camera state changes; iOS uses a Metal display callback for asynchronous resource progress and submits GPU frames only after state changes. The GLB is loaded from Flutter's bundled asset directory, centered and normalized from its glTF bounds, and released through gltfio before the Filament engine is destroyed.
