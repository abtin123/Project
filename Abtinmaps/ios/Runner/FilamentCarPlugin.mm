#import "FilamentCarPlugin.h"
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

#include <filament/Engine.h>
#include <filament/Renderer.h>
#include <filament/SwapChain.h>
#include <filament/View.h>
#include <filament/Scene.h>
#include <filament/RenderableManager.h>
#include <filament/Camera.h>
#include <filament/LightManager.h>
#include <filament/MaterialInstance.h>
#include <filament/IndirectLight.h>
#include <filament/Texture.h>
#include <filament/TransformManager.h>
#include <filament/Box.h>
#include <filament/Viewport.h>
#include <gltfio/AssetLoader.h>
#include <gltfio/FilamentAsset.h>
#include <gltfio/MaterialProvider.h>
#include <gltfio/ResourceLoader.h>
#include <gltfio/TextureProvider.h>
#include <gltfio/materials/uberarchive.h>
#include <utils/EntityManager.h>
#include <math/mat4.h>
#include <math/vec3.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <stdexcept>
#include <vector>

using namespace filament;
using namespace filament::gltfio;

static NSString * const kFilamentChannel = @"ir.abtin.abtin_maps/filament_car";
static NSString * const kFilamentViewType = @"abtin/filament_car";

@interface AbtinFilamentSurface : UIView
@property(nonatomic, copy) void (^layoutHandler)(CGSize size, CGFloat scale);
@end

@implementation AbtinFilamentSurface
+ (Class)layerClass { return [CAMetalLayer class]; }
- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.contentScaleFactor = UIScreen.mainScreen.nativeScale;
    CAMetalLayer *metal = (CAMetalLayer *)self.layer;
    metal.device = MTLCreateSystemDefaultDevice();
    metal.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metal.framebufferOnly = YES;
    metal.opaque = NO;
    metal.backgroundColor = UIColor.clearColor.CGColor;
    metal.contentsScale = self.contentScaleFactor;
    metal.drawableSize = CGSizeMake(frame.size.width * self.contentScaleFactor,
                                    frame.size.height * self.contentScaleFactor);
  }
  return self;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  if (self.layoutHandler) self.layoutHandler(self.bounds.size, self.contentScaleFactor);
}
@end

class AbtinFilamentRenderer final {
 public:
  AbtinFilamentRenderer(CAMetalLayer *layer, NSString *assetPath, double theta, double phi)
      : layer_(layer), theta_(theta), phi_(phi) {
    try {
      initialize();
      if (!assetPath.length) throw std::runtime_error("Missing GLB asset path");
      loadModel(assetPath);
      dirty_ = true;
    } catch (...) {
      shutdown();
      throw;
    }
  }

  ~AbtinFilamentRenderer() { shutdown(); }

  void resize(double widthPoints, double heightPoints, double scale) {
    if (!engine_ || !layer_) return;
    const uint32_t width = (uint32_t)std::max(1.0, std::round(widthPoints * scale));
    const uint32_t height = (uint32_t)std::max(1.0, std::round(heightPoints * scale));
    layer_.drawableSize = CGSizeMake(width, height);
    if (view_) view_->setViewport({0, 0, width, height});
    updateCamera();
    dirty_ = true;
  }

  void update(double theta, double phi) {
    if (std::isfinite(theta)) {
      theta_ = std::fmod(theta, 360.0);
      if (theta_ < 0) theta_ += 360.0;
    }
    if (std::isfinite(phi)) phi_ = std::clamp(phi, 2.0, 78.0);
    updateCamera();
    dirty_ = true;
  }

  void setBodyColor(int modelIndex, uint32_t argb) {
    if (modelIndex < 0 || modelIndex > 3) return;
    selectedBodyColor_ = argb;
    const bool isBmw = assetPath_ && [assetPath_ hasSuffix:@"bmw_i8.glb"];
    const bool isAcura = assetPath_ && [assetPath_ hasSuffix:@"acura_rsx.glb"];
    const bool isPatrol = assetPath_ && [assetPath_ hasSuffix:@"nissan_patrol.glb"];
    const bool isPickup = assetPath_ && [assetPath_ hasSuffix:@"nissan_4x4.glb"];
    if ((modelIndex == 0 && isBmw) || (modelIndex == 1 && isAcura) ||
        (modelIndex == 2 && isPatrol) || (modelIndex == 3 && isPickup)) {
      applyBodyColor(asset_, modelIndex, argb);
      dirty_ = true;
    }
  }

  void setModel(NSString *path) {
    if (!path.length || !engine_) return;
    if (pendingAssetPath_ && [pendingAssetPath_ isEqualToString:path]) return;
    if (assetPath_ && [assetPath_ isEqualToString:path]) {
      cancelPendingModelLoad();
      lastLoadError_ = nil;
      return;
    }
    loadModel(path);
    dirty_ = true;
  }

  bool isReady() const noexcept {
    return engine_ && renderer_ && swapChain_ && view_ && camera_ &&
        (asset_ != nullptr || pendingAsset_ != nullptr);
  }

  NSString *failureReason() const noexcept {
    return lastLoadError_ ?: @"Filament renderer or GLB model is not ready";
  }

  NSString *modelState() const noexcept {
    if (pendingAsset_) return @"loading";
    if (asset_) return @"ready";
    return lastLoadError_ ? @"failed" : @"loading";
  }

  void updateAsyncLoad() { pollModelLoad(); }

  void renderIfNeeded() {
    if (!dirty_ || !renderer_ || !swapChain_ || !view_) return;
    if (!renderer_->beginFrame(swapChain_)) {
      // beginFrame can legitimately fail while iOS is transitioning the drawable.
      // Keep the frame dirty so the next display-link tick retries it.
      dirty_ = true;
      return;
    }
    dirty_ = false;
    renderer_->render(view_);
    renderer_->endFrame();
  }

 private:
  void initialize() {
    if (!layer_ || !layer_.device) {
      throw std::runtime_error("Metal is unavailable: CAMetalLayer has no MTLDevice");
    }
    engine_ = Engine::create(Engine::Backend::METAL);
    if (!engine_) throw std::runtime_error("Filament Engine::create(METAL) failed");

    renderer_ = engine_->createRenderer();
    Renderer::ClearOptions clear{};
    clear.clear = true;
    clear.clearColor = {0.0f, 0.0f, 0.0f, 0.0f};
    renderer_->setClearOptions(clear);

    scene_ = engine_->createScene();
    buildEnvironment();
    view_ = engine_->createView();
    view_->setScene(scene_);
    view_->setBlendMode(View::BlendMode::TRANSLUCENT);
    view_->setAntiAliasing(View::AntiAliasing::FXAA);
    view_->setPostProcessingEnabled(true);

    cameraEntity_ = utils::EntityManager::get().create();
    camera_ = engine_->createCamera(cameraEntity_);
    camera_->setExposure(16.0f, 1.0f / 125.0f, 100.0f);
    view_->setCamera(camera_);

    swapChain_ = engine_->createSwapChain((__bridge void *)layer_, SwapChain::CONFIG_TRANSPARENT);
    if (!swapChain_) throw std::runtime_error("Filament could not create Metal swap chain");

    // iOS ships Filament's gltfio_core target, which intentionally excludes the JIT
    // material provider. Use the official, version-matched gltfio ubershader archive.
    materialProvider_ = createUbershaderProvider(
        engine_, UBERARCHIVE_DEFAULT_DATA, UBERARCHIVE_DEFAULT_SIZE);
    if (!materialProvider_) throw std::runtime_error("Filament ubershader material provider failed");
    AssetConfiguration assetConfig{};
    assetConfig.engine = engine_;
    assetConfig.materials = materialProvider_;
    assetLoader_ = AssetLoader::create(assetConfig);
    if (!assetLoader_) throw std::runtime_error("Filament AssetLoader creation failed");

    textureProvider_ = createStbProvider(engine_);
    if (!textureProvider_) throw std::runtime_error("Filament texture decoder creation failed");
    ResourceConfiguration resourceConfig{};
    resourceConfig.engine = engine_;
    resourceConfig.gltfPath = "";
    resourceConfig.normalizeSkinningWeights = true;
    resourceLoader_ = new ResourceLoader(resourceConfig);
    resourceLoader_->addTextureProvider("image/png", textureProvider_);
    resourceLoader_->addTextureProvider("image/jpeg", textureProvider_);

    lightEntity_ = utils::EntityManager::get().create();
    LightManager::Builder(LightManager::Type::DIRECTIONAL)
        .color({1.0f, 0.97f, 0.92f})
        .intensity(55000.0f)
        .direction({-0.45f, -0.85f, -0.55f})
        .castShadows(false)
        .build(*engine_, lightEntity_);
    scene_->addEntity(lightEntity_);
  }

  void buildEnvironment() {
    // Six studio-like cubemap faces provide stable metallic reflections on iOS,
    // matching the procedural environment used by the Android renderer.
    reflectionTexture_ = Texture::Builder()
        .width(4).height(4).levels(3)
        .sampler(Texture::Sampler::SAMPLER_CUBEMAP)
        .format(Texture::InternalFormat::RGBA8)
        .build(*engine_);
    if (!reflectionTexture_) throw std::runtime_error("Filament reflection cubemap creation failed");

    static const uint8_t kFaces[384] = {
        230, 232, 235, 255, 230, 232, 235, 255, 230, 232, 235, 255, 230, 232, 235, 255,
        230, 232, 235, 255, 230, 232, 235, 255, 230, 232, 235, 255, 230, 232, 235, 255,
        230, 232, 235, 255, 230, 232, 235, 255, 230, 232, 235, 255, 230, 232, 235, 255,
        230, 232, 235, 255, 230, 232, 235, 255, 230, 232, 235, 255, 230, 232, 235, 255,
        95, 105, 120, 255, 95, 105, 120, 255, 95, 105, 120, 255, 95, 105, 120, 255,
        95, 105, 120, 255, 95, 105, 120, 255, 95, 105, 120, 255, 95, 105, 120, 255,
        95, 105, 120, 255, 95, 105, 120, 255, 95, 105, 120, 255, 95, 105, 120, 255,
        95, 105, 120, 255, 95, 105, 120, 255, 95, 105, 120, 255, 95, 105, 120, 255,
        155, 185, 220, 255, 155, 185, 220, 255, 155, 185, 220, 255, 155, 185, 220, 255,
        155, 185, 220, 255, 155, 185, 220, 255, 155, 185, 220, 255, 155, 185, 220, 255,
        155, 185, 220, 255, 155, 185, 220, 255, 155, 185, 220, 255, 155, 185, 220, 255,
        155, 185, 220, 255, 155, 185, 220, 255, 155, 185, 220, 255, 155, 185, 220, 255,
        70, 65, 60, 255, 70, 65, 60, 255, 70, 65, 60, 255, 70, 65, 60, 255,
        70, 65, 60, 255, 70, 65, 60, 255, 70, 65, 60, 255, 70, 65, 60, 255,
        70, 65, 60, 255, 70, 65, 60, 255, 70, 65, 60, 255, 70, 65, 60, 255,
        70, 65, 60, 255, 70, 65, 60, 255, 70, 65, 60, 255, 70, 65, 60, 255,
        215, 220, 225, 255, 215, 220, 225, 255, 215, 220, 225, 255, 215, 220, 225, 255,
        215, 220, 225, 255, 215, 220, 225, 255, 215, 220, 225, 255, 215, 220, 225, 255,
        215, 220, 225, 255, 215, 220, 225, 255, 215, 220, 225, 255, 215, 220, 225, 255,
        215, 220, 225, 255, 215, 220, 225, 255, 215, 220, 225, 255, 215, 220, 225, 255,
        115, 125, 140, 255, 115, 125, 140, 255, 115, 125, 140, 255, 115, 125, 140, 255,
        115, 125, 140, 255, 115, 125, 140, 255, 115, 125, 140, 255, 115, 125, 140, 255,
        115, 125, 140, 255, 115, 125, 140, 255, 115, 125, 140, 255, 115, 125, 140, 255,
        115, 125, 140, 255, 115, 125, 140, 255, 115, 125, 140, 255, 115, 125, 140, 255
    };
    Texture::PixelBufferDescriptor pixels(
        const_cast<uint8_t *>(kFaces), sizeof(kFaces), Texture::Format::RGBA, Texture::Type::UBYTE);
    reflectionTexture_->setImage(*engine_, 0, 0, 0, 0, 4, 4, 6, std::move(pixels));
    reflectionTexture_->generateMipmaps(*engine_);

    const math::float3 ambientSH{0.38f, 0.40f, 0.44f};
    indirectLight_ = IndirectLight::Builder()
        .reflections(reflectionTexture_)
        .irradiance(1, &ambientSH)
        .intensity(22000.0f)
        .build(*engine_);
    if (!indirectLight_) throw std::runtime_error("Filament indirect light creation failed");
    scene_->setIndirectLight(indirectLight_);
  }

  void loadModel(NSString *path) {
    const char *raw = path.UTF8String;
    const std::string fileName = raw ? std::string(raw) : std::string();
    if (fileName.size() < 4 || fileName.substr(fileName.size() - 4) != ".glb") {
      throw std::runtime_error("Only bundled GLB vehicle assets are accepted");
    }

    cancelPendingModelLoad();
    lastLoadError_ = nil;
    NSString *bundlePath = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks/App.framework/flutter_assets"];
    NSString *filePath = path.isAbsolutePath ? path : [bundlePath stringByAppendingPathComponent:path];
    NSData *data = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMappedIfSafe error:nil];
    if (!data || data.length < 20) {
      throw std::runtime_error(std::string("Cannot read bundled GLB: ") + raw);
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (!(bytes[0] == 'g' && bytes[1] == 'l' && bytes[2] == 'T' && bytes[3] == 'F')) {
      throw std::runtime_error("Invalid GLB header");
    }

    FilamentAsset *candidate = assetLoader_->createAsset(bytes, (uint32_t)data.length);
    if (!candidate) throw std::runtime_error("Filament failed to parse GLB asset");
    if (!resourceLoader_->asyncBeginLoad(candidate)) {
      assetLoader_->destroyAsset(candidate);
      throw std::runtime_error("Filament ResourceLoader could not start asynchronous GLB loading");
    }
    pendingAsset_ = candidate;
    pendingSourceData_ = data; // gltfio may reference GLB source bytes until releaseSourceData().
    pendingAssetPath_ = [path copy];
    pendingLoadStartedAt_ = CACurrentMediaTime();
  }

  void pollModelLoad() {
    if (!pendingAsset_ || !resourceLoader_) return;
    try {
      resourceLoader_->asyncUpdateLoad();
      const float progress = resourceLoader_->asyncGetLoadProgress();
      if (!std::isfinite(progress) || progress < 0.0f) {
        throw std::runtime_error("Filament returned invalid asynchronous load progress");
      }
      if (progress < 1.0f) return;

      FilamentAsset *candidate = pendingAsset_;
      NSString *candidatePath = pendingAssetPath_;
      candidate->releaseSourceData();
      pendingSourceData_ = nil;
      normalizeAndAttach(candidate);
      pendingAsset_ = nullptr;
      pendingAssetPath_ = nil;
      assetPath_ = [candidatePath copy];
      lastLoadError_ = nil;
      NSLog(@"[filament-ios] GLB ready in %.0f ms (%s)",
            (CACurrentMediaTime() - pendingLoadStartedAt_) * 1000.0,
            assetPath_.lastPathComponent.UTF8String ?: "model");
      dirty_ = true;
    } catch (const std::exception &e) {
      if (pendingAsset_) scene_->removeEntities(pendingAsset_->getEntities(), pendingAsset_->getEntityCount());
      cancelPendingModelLoad();
      lastLoadError_ = [NSString stringWithUTF8String:e.what()] ?: @"GLB resource loading failed";
      NSLog(@"[filament-ios] async GLB load failed: %@", lastLoadError_);
    } catch (...) {
      if (pendingAsset_) scene_->removeEntities(pendingAsset_->getEntities(), pendingAsset_->getEntityCount());
      cancelPendingModelLoad();
      lastLoadError_ = @"Unknown error while loading GLB resources";
      NSLog(@"[filament-ios] async GLB load failed: %@", lastLoadError_);
    }
  }

  void applyBodyColor(FilamentAsset *target, int modelIndex, uint32_t argb) {
    if (!target || !engine_) return;
    const float r = ((argb >> 16) & 0xFF) / 255.0f;
    const float g = ((argb >> 8) & 0xFF) / 255.0f;
    const float b = (argb & 0xFF) / 255.0f;

    const auto isBodyNode = [modelIndex](const char *name) {
      if (!name) return false;
      switch (modelIndex) {
        case 0:
          return std::strcmp(name, "mesh.001_paint_0") == 0;
        case 1:
          return std::strcmp(name, "Mesh2__RSX_0") == 0 ||
                 std::strcmp(name, "Mesh4__RSX_0") == 0;
        case 2:
          return std::strcmp(name, "Object_3") == 0;
        case 3:
          return std::strcmp(name, "Object_2") == 0;
        default: return false;
      }
    };
    auto &renderables = engine_->getRenderableManager();
    const utils::Entity *entities = target->getRenderableEntities();
    const size_t entityCount = target->getRenderableEntityCount();
    size_t updated = 0;
    for (size_t i = 0; i < entityCount; ++i) {
      const utils::Entity entity = entities[i];
      if (!isBodyNode(target->getName(entity))) continue;
      const auto instance = renderables.getInstance(entity);
      if (!instance) continue;
      const size_t primitiveCount = renderables.getPrimitiveCount(instance);
      for (size_t primitive = 0; primitive < primitiveCount; ++primitive) {
        MaterialInstance *material = renderables.getMaterialInstanceAt(instance, primitive);
        if (!material) continue;
        // Use the stable glTF node name, not MaterialInstance::getName(): gltfio
        // can rename instances and that must not prevent the vehicle from rendering.
        material->setParameter("baseColorFactor", math::float4(r, g, b, 1.0f));
        ++updated;
      }
    }
    if (updated == 0) {
      NSLog(@"[filament-ios] body material not found for model index %d", modelIndex);
    }
  }

  void normalizeAndAttach(FilamentAsset *candidate) {
    const Aabb bounds = candidate->getBoundingBox();
    const math::float3 center = bounds.center();
    const math::float3 half = bounds.extent();
    const float radius = std::sqrt(half.x * half.x + half.y * half.y + half.z * half.z);
    if (!std::isfinite(radius) || radius < 1e-4f) {
      throw std::runtime_error("GLB has invalid or empty bounds");
    }
    const float scale = 1.0f / radius;
    auto &transforms = engine_->getTransformManager();
    const auto instance = transforms.getInstance(candidate->getRoot());
    const math::mat4f transform =
        math::mat4f::translation(math::float3(-center.x * scale, -center.y * scale, -center.z * scale)) *
        math::mat4f::scaling(math::float3(scale));
    transforms.setTransform(instance, transform);

    // Attach the fully loaded replacement before releasing the old asset.
    scene_->addEntities(candidate->getEntities(), candidate->getEntityCount());
    const int bodyIndex = [pendingAssetPath_ hasSuffix:@"bmw_i8.glb"] ? 0 :
        ([pendingAssetPath_ hasSuffix:@"acura_rsx.glb"] ? 1 :
        ([pendingAssetPath_ hasSuffix:@"nissan_patrol.glb"] ? 2 :
        ([pendingAssetPath_ hasSuffix:@"nissan_4x4.glb"] ? 3 : -1)));
    if (bodyIndex >= 0) applyBodyColor(candidate, bodyIndex, selectedBodyColor_);
    if (asset_) {
      scene_->removeEntities(asset_->getEntities(), asset_->getEntityCount());
      assetLoader_->destroyAsset(asset_);
    }
    asset_ = candidate;
  }

  void cancelPendingModelLoad() {
    if (!pendingAsset_) return;
    resourceLoader_->asyncCancelLoad();
    assetLoader_->destroyAsset(pendingAsset_);
    pendingAsset_ = nullptr;
    pendingSourceData_ = nil;
    pendingAssetPath_ = nil;
  }

  void updateCamera() {
    if (!camera_) return;
    const double theta = theta_ * M_PI / 180.0;
    const double phi = phi_ * M_PI / 180.0;
    constexpr double fov = 32.0;
    const double distance = 1.0 / std::sin(fov * M_PI / 360.0) * 1.04;
    const double x = distance * std::sin(phi) * std::sin(theta);
    const double y = distance * std::cos(phi);
    const double z = distance * std::sin(phi) * std::cos(theta);
    const CGSize size = layer_.bounds.size;
    const double aspect = (size.width > 0 && size.height > 0) ? size.width / size.height : 1.0;
    camera_->setProjection(fov, aspect, 0.05, 20.0, Camera::Fov::VERTICAL);
    camera_->lookAt({x, y, z}, {0.0, 0.0, 0.0}, {0.0, 1.0, 0.0});
  }

  void shutdown() {
    if (!engine_) return;
    if (pendingAsset_) {
      try {
        scene_->removeEntities(pendingAsset_->getEntities(), pendingAsset_->getEntityCount());
        cancelPendingModelLoad();
      } catch (...) {}
    }
    if (asset_) {
      scene_->removeEntities(asset_->getEntities(), asset_->getEntityCount());
      assetLoader_->destroyAsset(asset_);
      asset_ = nullptr;
    }
    if (scene_) scene_->setIndirectLight(nullptr);
    if (indirectLight_) { engine_->destroy(indirectLight_); indirectLight_ = nullptr; }
    if (reflectionTexture_) { engine_->destroy(reflectionTexture_); reflectionTexture_ = nullptr; }
    if (resourceLoader_) {
      delete resourceLoader_;
      resourceLoader_ = nullptr;
    }
    if (textureProvider_) { delete textureProvider_; textureProvider_ = nullptr; }
    if (assetLoader_) { AssetLoader::destroy(&assetLoader_); }
    if (materialProvider_) {
      materialProvider_->destroyMaterials();
      delete materialProvider_;
      materialProvider_ = nullptr;
    }
    if (view_) { engine_->destroy(view_); view_ = nullptr; }
    if (scene_) { engine_->destroy(scene_); scene_ = nullptr; }
    if (renderer_) { engine_->destroy(renderer_); renderer_ = nullptr; }
    if (swapChain_) { engine_->destroy(swapChain_); swapChain_ = nullptr; }
    if (cameraEntity_) {
      engine_->destroy(cameraEntity_);
      utils::EntityManager::get().destroy(cameraEntity_);
      cameraEntity_ = {};
    }
    if (lightEntity_) {
      engine_->destroy(lightEntity_);
      utils::EntityManager::get().destroy(lightEntity_);
      lightEntity_ = {};
    }
    engine_->flushAndWait();
    Engine::destroy(&engine_);
  }

  __strong CAMetalLayer *layer_;
  Engine *engine_ = nullptr;
  Renderer *renderer_ = nullptr;
  SwapChain *swapChain_ = nullptr;
  Scene *scene_ = nullptr;
  View *view_ = nullptr;
  Camera *camera_ = nullptr;
  utils::Entity cameraEntity_{};
  utils::Entity lightEntity_{};
  MaterialProvider *materialProvider_ = nullptr;
  AssetLoader *assetLoader_ = nullptr;
  ResourceLoader *resourceLoader_ = nullptr;
  TextureProvider *textureProvider_ = nullptr;
  Texture *reflectionTexture_ = nullptr;
  IndirectLight *indirectLight_ = nullptr;
  FilamentAsset *asset_ = nullptr;
  uint32_t selectedBodyColor_ = 0xFFFFFFFF;
  FilamentAsset *pendingAsset_ = nullptr;
  __strong NSData *pendingSourceData_ = nil;
  __strong NSString *assetPath_ = nil;
  __strong NSString *pendingAssetPath_ = nil;
  __strong NSString *lastLoadError_ = nil;
  CFTimeInterval pendingLoadStartedAt_ = 0.0;
  double theta_ = 180.0;
  double phi_ = 60.0;
  bool dirty_ = true;
};

@protocol AbtinFilamentRenderTarget <NSObject>
- (void)renderFrame;
@end

@interface AbtinFilamentDisplayLinkProxy : NSObject
@property(nonatomic, weak) id<AbtinFilamentRenderTarget> target;
- (void)tick:(CADisplayLink *)displayLink;
@end
@implementation AbtinFilamentDisplayLinkProxy
- (void)tick:(CADisplayLink *)displayLink {
  [self.target renderFrame];
}
@end

@interface AbtinFilamentPlatformView : NSObject<FlutterPlatformView, AbtinFilamentRenderTarget> {
 @private
  AbtinFilamentSurface *_surface;
  AbtinFilamentRenderer *_renderer;
  CADisplayLink *_displayLink;
  AbtinFilamentDisplayLinkProxy *_displayProxy;
  int64_t _viewId;
  NSString *_failureReason;
}
- (instancetype)initWithFrame:(CGRect)frame
                viewIdentifier:(int64_t)viewId
                     arguments:(NSDictionary *)arguments
                    assetLookup:(NSString * (^)(NSString *))assetLookup;
- (void)updateTheta:(double)theta phi:(double)phi;
- (void)setModel:(NSString *)assetPath assetLookup:(NSString * (^)(NSString *))assetLookup;
- (void)setBodyColor:(NSInteger)modelIndex argb:(uint32_t)argb;
- (BOOL)isReady;
- (NSString *)failureReason;
- (NSString *)modelState;
@end

@implementation AbtinFilamentPlatformView
- (instancetype)initWithFrame:(CGRect)frame
                viewIdentifier:(int64_t)viewId
                     arguments:(NSDictionary *)arguments
                    assetLookup:(NSString * (^)(NSString *))assetLookup {
  self = [super init];
  if (self) {
    _viewId = viewId;
    _surface = [[AbtinFilamentSurface alloc] initWithFrame:frame];
    NSString *asset = [arguments[@"asset"] isKindOfClass:NSString.class] ? arguments[@"asset"] : @"assets/models/nissan_4x4.glb";
    const double theta = [arguments[@"theta"] respondsToSelector:@selector(doubleValue)] ? [arguments[@"theta"] doubleValue] : 180.0;
    const double phi = [arguments[@"phi"] respondsToSelector:@selector(doubleValue)] ? [arguments[@"phi"] doubleValue] : 60.0;
    NSString *resolved = assetLookup(asset);
    NSString *frameworkAssets = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/App.framework/flutter_assets"];
    NSString *relativeKey = resolved ?: asset;
    if ([relativeKey hasPrefix:@"flutter_assets/"]) relativeKey = [relativeKey substringFromIndex:15];
    NSString *fullPath = [frameworkAssets stringByAppendingPathComponent:relativeKey];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
      fullPath = [frameworkAssets stringByAppendingPathComponent:asset];
    }
    try {
      _renderer = new AbtinFilamentRenderer((CAMetalLayer *)_surface.layer, fullPath, theta, phi);
      __weak AbtinFilamentPlatformView *weakSelf = self;
      _surface.layoutHandler = ^(CGSize size, CGFloat scale) {
        // Promote weakSelf to a strong local before touching ivars. UIKit may
        // deliver a layout callback while the platform view is being torn down.
        AbtinFilamentPlatformView *strongSelf = weakSelf;
        if (!strongSelf) return;
        AbtinFilamentRenderer *renderer = strongSelf->_renderer;
        if (renderer) renderer->resize(size.width, size.height, scale);
      };
      _surface.layoutHandler(_surface.bounds.size, _surface.contentScaleFactor);
    } catch (const std::exception &e) {
      _failureReason = [NSString stringWithUTF8String:e.what()] ?: @"Unknown Filament initialization error";
      NSLog(@"[filament-ios] init failed: %@", _failureReason);
      _renderer = nullptr;
    } catch (...) {
      _failureReason = @"Unknown C++ exception while initializing Filament";
      NSLog(@"[filament-ios] init failed: %@", _failureReason);
      _renderer = nullptr;
    }
    _displayProxy = [[AbtinFilamentDisplayLinkProxy alloc] init];
    _displayProxy.target = self;
    _displayLink = [CADisplayLink displayLinkWithTarget:_displayProxy selector:@selector(tick:)];
    _displayLink.preferredFramesPerSecond = 30;
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  }
  return self;
}
- (UIView *)view { return _surface; }
- (BOOL)isReady { return _renderer && _renderer->isReady(); }
- (NSString *)failureReason {
  if (_failureReason) return _failureReason;
  return _renderer ? _renderer->failureReason() : @"Filament renderer is not ready";
}
- (NSString *)modelState {
  return _renderer ? _renderer->modelState() : @"failed";
}
- (void)renderFrame {
  if (!_renderer) return;
  // Keep async gltfio decoding progressing even while the platform view is temporarily detached.
  _renderer->updateAsyncLoad();
  // UIKit / Metal drawables are only valid while the platform view is attached.
  if (_surface.window) _renderer->renderIfNeeded();
}
- (void)updateTheta:(double)theta phi:(double)phi { if (_renderer) _renderer->update(theta, phi); }
- (void)setBodyColor:(NSInteger)modelIndex argb:(uint32_t)argb { if (_renderer) _renderer->setBodyColor((int)modelIndex, argb); }
- (void)setModel:(NSString *)assetPath assetLookup:(NSString * (^)(NSString *))assetLookup {
  if (!_renderer) return;
  NSString *resolved = assetLookup(assetPath);
  NSString *frameworkAssets = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/App.framework/flutter_assets"];
  NSString *relativeKey = resolved ?: assetPath;
  if ([relativeKey hasPrefix:@"flutter_assets/"]) relativeKey = [relativeKey substringFromIndex:15];
  NSString *fullPath = [frameworkAssets stringByAppendingPathComponent:relativeKey];
  if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
    fullPath = [frameworkAssets stringByAppendingPathComponent:assetPath];
  }
  try { _renderer->setModel(fullPath); }
  catch (const std::exception &e) { NSLog(@"[filament-ios] model update failed: %s", e.what()); }
}
- (void)dealloc {
  [_displayLink invalidate];
  _displayLink = nil;
  _displayProxy.target = nil;
  _displayProxy = nil;
  delete _renderer;
  _renderer = nullptr;
}
@end

@interface AbtinFilamentViewFactory : NSObject<FlutterPlatformViewFactory>
@property(nonatomic, weak) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, AbtinFilamentPlatformView *> *views;
@end

@implementation AbtinFilamentViewFactory
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];
  if (self) { _registrar = registrar; _views = [NSMutableDictionary dictionary]; }
  return self;
}
- (NSObject<FlutterMessageCodec> *)createArgsCodec { return FlutterStandardMessageCodec.sharedInstance; }
- (NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame
                                    viewIdentifier:(int64_t)viewId
                                         arguments:(id _Nullable)args {
  NSDictionary *arguments = [args isKindOfClass:NSDictionary.class] ? args : @{};
  __weak typeof(self) weakSelf = self;
  AbtinFilamentPlatformView *platformView = [[AbtinFilamentPlatformView alloc]
      initWithFrame:frame viewIdentifier:viewId arguments:arguments
      assetLookup:^NSString *(NSString *asset) {
        return [weakSelf.registrar lookupKeyForAsset:asset];
      }];
  self.views[@(viewId)] = platformView;
  return platformView;
}
@end

@interface FilamentCarPlugin ()
@property(nonatomic, strong) AbtinFilamentViewFactory *factory;
@property(nonatomic, strong) FlutterMethodChannel *channel;
@end

@implementation FilamentCarPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FilamentCarPlugin *instance = [[FilamentCarPlugin alloc] init];
  instance.factory = [[AbtinFilamentViewFactory alloc] initWithRegistrar:registrar];
  [registrar registerViewFactory:instance.factory withId:kFilamentViewType];
  instance.channel = [FlutterMethodChannel methodChannelWithName:kFilamentChannel binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:instance channel:instance.channel];
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  NSNumber *identifier = [args[@"id"] isKindOfClass:NSNumber.class] ? args[@"id"] : nil;
  AbtinFilamentPlatformView *platformView = identifier ? self.factory.views[identifier] : nil;
  if ([call.method isEqualToString:@"update"]) {
    [platformView updateTheta:[args[@"theta"] doubleValue] phi:[args[@"phi"] doubleValue]];
    result(nil);
  } else if ([call.method isEqualToString:@"bodyColor"]) {
    [platformView setBodyColor:[args[@"modelIndex"] integerValue] argb:(uint32_t)[args[@"argb"] unsignedIntValue]];
    result(nil);
  } else if ([call.method isEqualToString:@"model"]) {
    NSString *asset = [args[@"asset"] isKindOfClass:NSString.class] ? args[@"asset"] : nil;
    if (asset) {
      __weak AbtinFilamentViewFactory *factory = self.factory;
      [platformView setModel:asset assetLookup:^NSString *(NSString *value) {
        return [factory.registrar lookupKeyForAsset:value];
      }];
    }
    result(nil);
  } else if ([call.method isEqualToString:@"dispose"]) {
    if (identifier) [self.factory.views removeObjectForKey:identifier];
    result(nil);
  } else if ([call.method isEqualToString:@"viewReady"]) {
    if (!platformView) {
      result(@NO);
    } else {
      result(@([platformView isReady]));
    }
  } else if ([call.method isEqualToString:@"viewState"]) {
    result(platformView ? [platformView modelState] : @"failed");
  } else if ([call.method isEqualToString:@"status"]) {
    NSUInteger readyCount = 0;
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    for (AbtinFilamentPlatformView *item in self.factory.views.allValues) {
      if ([item isReady]) readyCount++;
      else [errors addObject:[item failureReason]];
    }
    NSString *status = [NSString stringWithFormat:@"Filament iOS / Metal views=%lu ready=%lu%@",
        (unsigned long)self.factory.views.count, (unsigned long)readyCount,
        errors.count ? [NSString stringWithFormat:@" errors=[%@]", [errors componentsJoinedByString:@"; "]] : @""];
    result(status);
  } else {
    result(FlutterMethodNotImplemented);
  }
}
@end
