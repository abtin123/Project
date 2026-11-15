package ir.abtin.abtinmaps

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import com.google.android.filament.Box
import com.google.android.filament.Camera
import com.google.android.filament.Engine
import com.google.android.filament.EntityManager
import com.google.android.filament.Filament
import com.google.android.filament.IndirectLight
import com.google.android.filament.LightManager
import com.google.android.filament.Renderer
import com.google.android.filament.Scene
import com.google.android.filament.SwapChain
import com.google.android.filament.SwapChainFlags
import com.google.android.filament.Texture
import com.google.android.filament.View
import com.google.android.filament.Viewport
import com.google.android.filament.gltfio.AssetLoader
import com.google.android.filament.gltfio.FilamentAsset
import com.google.android.filament.gltfio.Gltfio
import com.google.android.filament.gltfio.ResourceLoader
import com.google.android.filament.gltfio.UbershaderProvider
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * خودروی سه‌بعدیِ نقشه با موتور Filament گوگل، کاملاً بومی (Kotlin) و بدون WebView
 * و بدون هیچ پکیج فلاتری.
 *
 * معماری:
 *  - یک Engine مشترک؛ تمام APIهای Filament روی نخ اصلی اجرا می‌شوند، مطابق قرارداد رسمی gltfio Android.
 *  - هر خودرو یک [CarView] است که روی Surfaceِ یک SurfaceProducer فلاتر رندر می‌کند و آن را با
 *    ویجت `Texture(textureId)` نشان می‌دهد (شفاف، بدون PlatformView).
 *  - رندر «به‌ازای تغییر» است، نه پیوسته: فقط وقتی زاویه/اندازه/مدل عوض شود فریم
 *    می‌سازیم (حداکثر ~۲۰ فریم در ثانیه). همین نشت sync_file و فشار GPU را که با
 *    WebView داشتیم از بین می‌برد.
 *  - خطاهای native به Android logcat فرستاده می‌شوند: برچسب `filament`.
 */
private const val TAG = "filament"

/** آمار داخلی رندر برای وضعیت موتور (از هر ریسمانی امن است). */
object FilamentStats {
    val frames = AtomicLong(0)
    val skipped = AtomicLong(0)
    val views = AtomicInteger(0)
    val modelsLoaded = AtomicInteger(0)
    @Volatile var backend: String = "-"
    @Volatile var engineUp: Boolean = false
    @Volatile var lastLoadMs: Long = -1
    @Volatile var lastFrameMs: Float = -1f
    @Volatile var lastError: String? = null

    fun line(): String =
        "engine=${if (engineUp) "up" else "down"} backend=$backend views=${views.get()} " +
            "frames=${frames.get()} skipped=${skipped.get()} models=${modelsLoaded.get()} " +
            "lastFrame=${if (lastFrameMs >= 0) "%.1f".format(lastFrameMs) + "ms" else "-"} " +
            "lastLoad=${if (lastLoadMs >= 0) "${lastLoadMs}ms" else "-"}" +
            (lastError?.let { " lastError=$it" } ?: "")
}


private object FilamentRuntime {
    @Volatile private var initialized = false

    @Synchronized fun ensureInitialized() {
        if (initialized) return
        Filament.init()
        Gltfio.init()
        initialized = true
    }
}

/** Engine مشترک. Filament و gltfio Android باید از نخ اصلی فراخوانی شوند. */
private class FilamentHost {
    val handler = Handler(Looper.getMainLooper())

    lateinit var engine: Engine
    lateinit var assetLoader: AssetLoader
    private lateinit var materialProvider: UbershaderProvider
    var indirectLight: IndirectLight? = null
    private var iblTexture: Texture? = null
    private var sunEntity = 0
    private var fillEntity = 0
    var ready = false
        private set

    /** روی نخ اصلی Android صدا زده شود. */
    fun init(): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper()) { "FilamentHost.init must run on the main thread" }
        if (ready) return true
        return try {
            FilamentRuntime.ensureInitialized()
            val t0 = SystemClock.elapsedRealtime()
            engine = Engine.create()
            materialProvider = UbershaderProvider(engine)
            assetLoader = AssetLoader(engine, materialProvider, EntityManager.get())
            buildEnvironment()
            ready = true
            FilamentStats.lastError = null
            FilamentStats.engineUp = true
            FilamentStats.backend = try { engine.backend.name } catch (_: Throwable) { "?" }
            NativeLog.log(TAG, "engine created backend=${FilamentStats.backend} in ${SystemClock.elapsedRealtime() - t0}ms")
            true
        } catch (t: Throwable) {
            FilamentStats.lastError = "init: ${t.javaClass.simpleName}: ${t.message}"
            // Initialization can fail halfway through (e.g. unsupported GPU backend).
            // Release every object that was successfully created, in reverse order.
            try { if (::assetLoader.isInitialized) assetLoader.destroy() } catch (_: Throwable) {}
            try { if (::materialProvider.isInitialized) { materialProvider.destroyMaterials(); materialProvider.destroy() } } catch (_: Throwable) {}
            try { indirectLight?.let { if (::engine.isInitialized) engine.destroyIndirectLight(it) } } catch (_: Throwable) {}
            try {
                if (::engine.isInitialized) {
                    if (sunEntity != 0) engine.lightManager.destroy(sunEntity)
                    if (fillEntity != 0) engine.lightManager.destroy(fillEntity)
                    val em = EntityManager.get()
                    if (sunEntity != 0) em.destroy(sunEntity)
                    if (fillEntity != 0) em.destroy(fillEntity)
                }
            } catch (_: Throwable) {}
            try { iblTexture?.let { if (::engine.isInitialized) engine.destroyTexture(it) } } catch (_: Throwable) {}
            sunEntity = 0
            fillEntity = 0
            indirectLight = null
            iblTexture = null
            try { if (::engine.isInitialized) engine.destroy() } catch (_: Throwable) {}
            FilamentStats.engineUp = false
            ready = false
            NativeLog.log(TAG, "ENGINE INIT FAILED: $t\n${t.stackTraceToString().take(1500)}")
            false
        }
    }

    /** نور محیطی ساده و رویه‌ای (بدون فایل IBL) تا بدنهٔ فلزی خودرو سیاه نشود. */
    private fun buildEnvironment() {
        val levels = 6 // 32,16,8,4,2,1
        val size0 = 32
        val tex = Texture.Builder()
            .width(size0).height(size0)
            .levels(levels)
            .sampler(Texture.Sampler.SAMPLER_CUBEMAP)
            .format(Texture.InternalFormat.RGBA8)
            .build(engine)
        iblTexture = tex // register ownership immediately so partial initialization can clean it up
        for (level in 0 until levels) {
            val s = max(1, size0 shr level)
            val faceBytes = s * s * 4
            val buf = ByteBuffer.allocateDirect(faceBytes * 6)
            for (face in 0 until 6) {
                for (y in 0 until s) {
                    for (x in 0 until s) {
                        val u = 2f * (x + 0.5f) / s - 1f
                        val v = 2f * (y + 0.5f) / s - 1f
                        val d = faceDirection(face, u, v)
                        val c = environmentRadiance(d[0], d[1], d[2])
                        buf.put(toByte(c[0])).put(toByte(c[1])).put(toByte(c[2])).put(255.toByte())
                    }
                }
            }
            buf.flip()
            val pbd = Texture.PixelBufferDescriptor(buf, Texture.Format.RGBA, Texture.Type.UBYTE)
            tex.setImage(engine, level, pbd, IntArray(6) { it * faceBytes })
        }
        indirectLight = IndirectLight.Builder()
            .reflections(tex)
            .irradiance(1, floatArrayOf(0.78f, 0.80f, 0.84f))
            .intensity(IBL_INTENSITY)
            .build(engine)

        val em = EntityManager.get()
        sunEntity = em.create()
        LightManager.Builder(LightManager.Type.DIRECTIONAL)
            .color(1.0f, 0.97f, 0.92f)
            .intensity(SUN_INTENSITY)
            .direction(-0.45f, -0.85f, -0.55f)
            .castShadows(false)
            .build(engine, sunEntity)
        fillEntity = em.create()
        LightManager.Builder(LightManager.Type.DIRECTIONAL)
            .color(0.80f, 0.88f, 1.0f)
            .intensity(FILL_INTENSITY)
            .direction(0.6f, -0.3f, 0.7f)
            .castShadows(false)
            .build(engine, fillEntity)
    }

    fun addLights(scene: Scene) {
        scene.addEntity(sunEntity)
        scene.addEntity(fillEntity)
    }

    fun removeLights(scene: Scene) {
        scene.removeEntity(sunEntity)
        scene.removeEntity(fillEntity)
    }

    /** وقتی آخرین نما بسته شد؛ فقط روی نخ اصلی Android. */
    fun shutdown() {
        if (!ready) return
        // Do not let one failed destroy prevent the remaining GPU resources from being released.
        try { if (sunEntity != 0) engine.lightManager.destroy(sunEntity) } catch (t: Throwable) { NativeLog.log(TAG, "sun destroy: $t") }
        try { if (fillEntity != 0) engine.lightManager.destroy(fillEntity) } catch (t: Throwable) { NativeLog.log(TAG, "fill destroy: $t") }
        try {
            val em = EntityManager.get()
            if (sunEntity != 0) em.destroy(sunEntity)
            if (fillEntity != 0) em.destroy(fillEntity)
        } catch (t: Throwable) { NativeLog.log(TAG, "light entity destroy: $t") }
        try { indirectLight?.let { engine.destroyIndirectLight(it) } } catch (t: Throwable) { NativeLog.log(TAG, "IBL destroy: $t") }
        try { iblTexture?.let { engine.destroyTexture(it) } } catch (t: Throwable) { NativeLog.log(TAG, "IBL texture destroy: $t") }
        indirectLight = null
        iblTexture = null
        try { assetLoader.destroy() } catch (t: Throwable) { NativeLog.log(TAG, "asset loader destroy: $t") }
        try { materialProvider.destroyMaterials(); materialProvider.destroy() } catch (t: Throwable) { NativeLog.log(TAG, "material provider destroy: $t") }
        try { engine.flushAndWait(); engine.destroy() } catch (t: Throwable) { NativeLog.log(TAG, "engine destroy: $t") }
        sunEntity = 0
        fillEntity = 0
        ready = false
        FilamentStats.engineUp = false
        NativeLog.log(TAG, "engine destroyed")
    }

    // ---- محیط رویه‌ای ----
    private fun toByte(v: Float): Byte = (min(1f, max(0f, v)) * 255f + 0.5f).toInt().toByte()

    private fun faceDirection(face: Int, u: Float, v: Float): FloatArray {
        val x: Float; val y: Float; val z: Float
        when (face) {
            0 -> { x = 1f; y = -v; z = -u }
            1 -> { x = -1f; y = -v; z = u }
            2 -> { x = u; y = 1f; z = v }
            3 -> { x = u; y = -1f; z = -v }
            4 -> { x = u; y = -v; z = 1f }
            else -> { x = -u; y = -v; z = -1f }
        }
        val l = sqrt(x * x + y * y + z * z)
        return floatArrayOf(x / l, y / l, z / l)
    }

    private fun environmentRadiance(x: Float, y: Float, z: Float): FloatArray {
        // آسمان روشن ← افق ← زمین تیره + دو «سافت‌باکس» برای هایلایت روی بدنه.
        val t = (y * 0.5f + 0.5f)
        val sky = floatArrayOf(0.62f, 0.76f, 0.98f)
        val hor = floatArrayOf(0.88f, 0.89f, 0.90f)
        val gnd = floatArrayOf(0.20f, 0.19f, 0.18f)
        val c = FloatArray(3)
        for (i in 0..2) {
            c[i] = if (y >= 0f) hor[i] + (sky[i] - hor[i]) * min(1f, y * 1.6f)
            else hor[i] + (gnd[i] - hor[i]) * min(1f, -y * 2.2f)
        }
        val k1 = max(0f, x * 0.55f + y * 0.62f + z * 0.56f).pow(18f) * 0.9f
        val k2 = max(0f, -x * 0.70f + y * 0.30f - z * 0.64f).pow(14f) * 0.45f
        for (i in 0..2) c[i] = c[i] * (0.55f + 0.45f * t) + k1 + k2
        return c
    }

    companion object {
        // مقادیر فیزیکی Filament (اکسپوژر پیش‌فرض دوربین: f/16، 1/125s، ISO100).
        const val SUN_INTENSITY = 55_000f
        const val FILL_INTENSITY = 14_000f
        const val IBL_INTENSITY = 22_000f
    }
}

/** یک خودرو: View + Scene + Camera + SwapChain روی Surfaceِ SurfaceProducer فلاتر. فقط روی ریسمان Filament. */
private class CarView(
    private val host: FilamentHost,
    private val producer: TextureRegistry.SurfaceProducer,
    private val appContext: Context,
    var asset: String,
    var widthPx: Int,
    var heightPx: Int,
    var theta: Double,
    var phi: Double,
) {
    val id: Long = producer.id()

    private val engine get() = host.engine
    private var surface: Surface? = null
    private var swapChain: SwapChain? = null
    private var renderer: Renderer? = null
    private var scene: Scene? = null
    private var view: View? = null
    private var camera: Camera? = null
    private var cameraEntity = 0
    private var filamentAsset: FilamentAsset? = null
    private var resourceLoader: ResourceLoader? = null
    private var pendingAsset: FilamentAsset? = null
    private var pendingSourceBuffer: ByteBuffer? = null
    private var pendingAssetPath: String? = null
    private var pendingLoadStartedAt = 0L
    @Volatile private var modelLoadError: String? = null
    private var disposed = false
    private var renderPending = false
    private var lastRenderAt = 0L
    private var loadToken = 0
    private var framesSinceCreate = 0

    private val renderRunnable = Runnable {
        renderPending = false
        renderNow()
    }

    private var loadPollRunnable: Runnable? = null

    fun create() {
        FilamentStats.views.incrementAndGet()
        val eng = engine
        renderer = eng.createRenderer().also {
            // خروجی شفاف: پاک کردن به (0,0,0,0)
            it.clearOptions = Renderer.ClearOptions().apply {
                clear = true
                clearColor = floatArrayOf(0f, 0f, 0f, 0f)
            }
        }
        scene = eng.createScene()
        view = eng.createView().apply {
            scene = this@CarView.scene
            blendMode = View.BlendMode.TRANSLUCENT
            antiAliasing = View.AntiAliasing.FXAA
            isPostProcessingEnabled = true
            dithering = View.Dithering.NONE
        }
        cameraEntity = EntityManager.get().create()
        camera = eng.createCamera(cameraEntity).also {
            it.setExposure(16f, 1f / 125f, 100f)
        }
        view!!.camera = camera
        scene!!.indirectLight = host.indirectLight
        resourceLoader = ResourceLoader(eng)
        host.addLights(scene!!)
        installSurfaceCallback()
        recreateSurface()
        loadModel(asset)
        NativeLog.log(TAG, "view #$id created ${widthPx}x$heightPx asset=$asset")
    }

    /** Surface متعلق به SurfaceProducer فلاتر است؛ ما فقط SwapChain روی آن می‌سازیم. */
    private fun recreateSurface() {
        // Filament requires all work against the old native window to finish before
        // Flutter is allowed to resize or replace the producer's Surface.
        swapChain?.let { old ->
            engine.destroySwapChain(old)
            swapChain = null
            engine.flushAndWait()
        }
        val safeWidth = widthPx.coerceIn(1, 2048)
        val safeHeight = heightPx.coerceIn(1, 2048)
        producer.setSize(safeWidth, safeHeight)
        val s = try { producer.surface } catch (t: Throwable) {
            NativeLog.log(TAG, "view #$id surface access failed: $t")
            null
        }
        surface = s
        if (s != null && s.isValid) {
            swapChain = engine.createSwapChain(s, SwapChainFlags.CONFIG_TRANSPARENT)
        } else {
            NativeLog.log(TAG, "view #$id surface not valid yet")
        }
        view?.viewport = Viewport(0, 0, safeWidth, safeHeight)
        updateCamera()
    }

    /** فلاتر Surface را (مثلاً هنگام رفتن برنامه به پس‌زمینه) باطل می‌کند؛ روی نخ اصلی. */
    private fun onSurfaceCleanup() {
        if (disposed) return
        host.handler.removeCallbacks(renderRunnable)
        renderPending = false
        swapChain?.let { engine.destroySwapChain(it) }
        swapChain = null
        surface = null
        try { engine.flushAndWait() } catch (_: Throwable) {}
        NativeLog.log(TAG, "view #$id surface cleanup (swapchain destroyed)")
    }

    private fun onSurfaceAvailable() {
        if (disposed) return
        recreateSurface()
        requestRender(force = true)
        NativeLog.log(TAG, "view #$id surface available again (swapchain recreated)")
    }

    private fun installSurfaceCallback() {
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                val action = Runnable {
                    try { this@CarView.onSurfaceAvailable() } catch (t: Throwable) {
                        FilamentStats.lastError = "surface available: ${t.javaClass.simpleName}: ${t.message}"
                        NativeLog.log(TAG, "SURFACE AVAILABLE FAILED view #$id: $t")
                    }
                }
                if (Looper.myLooper() == Looper.getMainLooper()) action.run() else host.handler.post(action)
            }

            override fun onSurfaceCleanup() {
                // Filament must release the old Surface before Flutter returns from cleanup.
                val action = Runnable {
                    try { this@CarView.onSurfaceCleanup() } catch (t: Throwable) {
                        FilamentStats.lastError = "surface cleanup: ${t.javaClass.simpleName}: ${t.message}"
                        NativeLog.log(TAG, "SURFACE CLEANUP FAILED view #$id: $t")
                    }
                }
                if (Looper.myLooper() == Looper.getMainLooper()) {
                    action.run()
                } else {
                    val latch = CountDownLatch(1)
                    val posted = host.handler.post { try { action.run() } finally { latch.countDown() } }
                    if (posted) latch.await()
                }
            }
        })
    }

    fun resize(w: Int, h: Int) {
        if (disposed || (w == widthPx && h == heightPx)) return
        widthPx = w
        heightPx = h
        recreateSurface()
        requestRender(force = true)
    }

    fun setOrbit(t: Double, p: Double) {
        if (disposed) return
        theta = if (t.isFinite()) ((t % 360.0) + 360.0) % 360.0 else 180.0
        phi = if (p.isFinite()) p.coerceIn(2.0, 78.0) else 60.0
        updateCamera()
        requestRender()
    }

    fun isModelViewReady(): Boolean = !disposed && renderer != null && view != null &&
        (filamentAsset != null || pendingAsset != null)

    fun modelState(): String = when {
        disposed -> "failed"
        pendingAsset != null -> "loading"
        filamentAsset != null -> "ready"
        modelLoadError != null -> "failed"
        else -> "loading"
    }

    fun setModel(newAsset: String) {
        if (disposed || newAsset == pendingAssetPath) return
        if (newAsset == asset && filamentAsset != null) {
            // The user may have switched back while another model was still loading.
            cancelPendingModelLoad()
            return
        }
        loadModel(newAsset)
    }

    /** Starts gltfio's asynchronous resource path; all ResourceLoader calls stay on Android main. */
    private fun loadModel(path: String) {
        cancelPendingModelLoad()
        val token = ++loadToken
        val t0 = SystemClock.elapsedRealtime()
        var createdAsset: FilamentAsset? = null
        modelLoadError = null
        try {
            require(path.startsWith("assets/models/") && path.endsWith(".glb")) {
                "Only bundled GLB vehicle assets are allowed: $path"
            }
            val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(path)
            val bytes = appContext.assets.open(key).use { it.readBytes() }
            require(bytes.size >= 20 && bytes[0] == 'g'.code.toByte() &&
                bytes[1] == 'l'.code.toByte() && bytes[2] == 'T'.code.toByte() &&
                bytes[3] == 'F'.code.toByte()) { "Invalid GLB header: $path" }
            val buf = ByteBuffer.allocateDirect(bytes.size).put(bytes).apply { flip() }
            val candidate = host.assetLoader.createAsset(buf)
                ?: throw IllegalStateException("createAsset returned null for $path")
            createdAsset = candidate
            if (token != loadToken || disposed) {
                host.assetLoader.destroyAsset(candidate)
                createdAsset = null
                return
            }
            val loader = resourceLoader ?: throw IllegalStateException("ResourceLoader is unavailable")
            if (!loader.asyncBeginLoad(candidate)) {
                throw IllegalStateException("asyncBeginLoad returned false for $path")
            }
            pendingAsset = candidate
            pendingSourceBuffer = buf // gltfio may retain source bytes until releaseSourceData()
            pendingAssetPath = path
            createdAsset = null // ownership transferred to pendingAsset
            pendingLoadStartedAt = t0
            NativeLog.log(TAG, "view #$id async GLB load started $path ${bytes.size / 1024}KB")
            pollModelLoad(token)
        } catch (t: Throwable) {
            createdAsset?.let { try { host.assetLoader.destroyAsset(it) } catch (_: Throwable) {} }
            modelLoadError = "${t.javaClass.simpleName}: ${t.message}"
            FilamentStats.lastError = "model $path: ${t.javaClass.simpleName}: ${t.message}"
            NativeLog.log(TAG, "MODEL LOAD FAILED $path: $t\n${t.stackTraceToString().take(1200)}")
        }
    }

    private fun pollModelLoad(token: Int) {
        if (disposed || token != loadToken) return
        val candidate = pendingAsset ?: return
        val loader = resourceLoader ?: return
        try {
            loader.asyncUpdateLoad()
            val progress = loader.asyncGetLoadProgress()
            check(progress.isFinite() && progress >= 0f) { "Invalid gltfio async load progress: $progress" }
            if (progress < 1f) {
                scheduleModelLoadPoll(token)
                return
            }
            loadPollRunnable = null
            candidate.releaseSourceData()
            pendingSourceBuffer = null
            normalizeAndAttach(candidate, pendingAssetPath ?: asset)
            pendingAsset = null
            pendingAssetPath = null
            val ms = SystemClock.elapsedRealtime() - pendingLoadStartedAt
            FilamentStats.lastLoadMs = ms
            modelLoadError = null
            FilamentStats.lastError = null
            FilamentStats.modelsLoaded.incrementAndGet()
            NativeLog.log(TAG, "view #$id model loaded ${asset} in ${ms}ms entities=${candidate.entities.size}")
            requestRender(force = true)
            host.handler.postDelayed({ if (!disposed) requestRender(force = true) }, 80L)
        } catch (t: Throwable) {
            try { scene?.removeEntities(candidate.entities) } catch (_: Throwable) {}
            try { loader.asyncCancelLoad() } catch (_: Throwable) {}
            pendingAsset = null
            pendingSourceBuffer = null
            pendingAssetPath = null
            loadPollRunnable = null
            try { host.assetLoader.destroyAsset(candidate) } catch (_: Throwable) {}
            modelLoadError = "${t.javaClass.simpleName}: ${t.message}"
            FilamentStats.lastError = "model load: ${t.javaClass.simpleName}: ${t.message}"
            NativeLog.log(TAG, "ASYNC MODEL LOAD FAILED: $t\n${t.stackTraceToString().take(1200)}")
        }
    }

    private fun normalizeAndAttach(candidate: FilamentAsset, path: String?) {
        // نرمال‌سازی: مرکز مدل در مبدأ و شعاع کرهٔ محیطی = ۱
        val box: Box = candidate.boundingBox
        val rawCenter = box.center
        val rawHalf = box.halfExtent
        val c = FloatArray(3) { i -> rawCenter[i].takeIf { it.isFinite() } ?: 0f }
        val h = FloatArray(3) { i -> rawHalf[i].takeIf { it.isFinite() && it >= 0f } ?: 0f }
        val radius = sqrt(h[0] * h[0] + h[1] * h[1] + h[2] * h[2])
            .takeIf { it.isFinite() && it > 1e-4f }
            ?: throw IllegalStateException("Model has an empty or invalid bounding box: $path")
        val scale = 1f / radius
        val tm = engine.transformManager
        val instance = tm.getInstance(candidate.root)
        check(instance != 0) { "GLB root transform is missing: $path" }
        tm.setTransform(
            instance,
            floatArrayOf(
                scale, 0f, 0f, 0f,
                0f, scale, 0f, 0f,
                0f, 0f, scale, 0f,
                -c[0] * scale, -c[1] * scale, -c[2] * scale, 1f,
            )
        )
        // Attach the replacement before removing the current model; the frame is submitted only
        // after this transaction completes, so the user never sees an intermediate empty scene.
        scene!!.addEntities(candidate.entities)
        if (!unloadModel()) {
            try { scene?.removeEntities(candidate.entities) } catch (_: Throwable) {}
            throw IllegalStateException("Could not safely release the previous vehicle model")
        }
        filamentAsset = candidate
        if (path != null) asset = path
    }

    private fun scheduleModelLoadPoll(token: Int) {
        val poll = Runnable { pollModelLoad(token) }
        loadPollRunnable = poll
        host.handler.postDelayed(poll, 16L)
    }

    private fun cancelPendingModelLoad() {
        ++loadToken
        loadPollRunnable?.let { host.handler.removeCallbacks(it) }
        loadPollRunnable = null
        val candidate = pendingAsset ?: return
        try { resourceLoader?.asyncCancelLoad() } catch (t: Throwable) {
            NativeLog.log(TAG, "cancel async model load #$id: $t")
        }
        pendingAsset = null
        pendingSourceBuffer = null
        pendingAssetPath = null
        try { host.assetLoader.destroyAsset(candidate) } catch (t: Throwable) {
            NativeLog.log(TAG, "destroy cancelled model #$id: $t")
        }
    }

    private fun unloadModel(): Boolean {
        val a = filamentAsset ?: return true
        return try {
            scene?.removeEntities(a.entities)
            host.assetLoader.destroyAsset(a)
            filamentAsset = null
            true
        } catch (t: Throwable) {
            // Keep the reference so dispose can retry rather than losing ownership of a live asset.
            NativeLog.log(TAG, "unload error (asset retained for retry): $t")
            false
        }
    }

    /** دوربین مداری: همان قرارداد model-viewer (theta افقی، phi از بالا). */
    private fun updateCamera() {
        val cam = camera ?: return
        val th = Math.toRadians(theta)
        val ph = Math.toRadians(phi)
        val dist = CAMERA_DISTANCE
        val ex = dist * sin(ph) * sin(th)
        val ey = dist * cos(ph)
        val ez = dist * sin(ph) * cos(th)
        val aspect = widthPx.toDouble() / max(1, heightPx)
        cam.setProjection(FOV_DEGREES, aspect, 0.05, 20.0, Camera.Fov.VERTICAL)
        cam.lookAt(ex, ey, ez, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)
    }

    /** رندر «تنبل»: حداکثر یک فریم در هر MIN_FRAME_GAP_MS. */
    fun requestRender(force: Boolean = false) {
        if (disposed || renderPending) return
        val since = SystemClock.elapsedRealtime() - lastRenderAt
        val wait = if (force) 0L else max(0L, MIN_FRAME_GAP_MS - since)
        renderPending = true
        host.handler.postDelayed(renderRunnable, wait)
    }

    private fun renderNow() {
        if (disposed) return
        val sc = swapChain ?: return
        val r = renderer ?: return
        val v = view ?: return
        val t0 = SystemClock.elapsedRealtimeNanos()
        var frameStarted = false
        try {
            frameStarted = r.beginFrame(sc, System.nanoTime())
            if (frameStarted) {
                r.render(v)
                FilamentStats.frames.incrementAndGet()
                framesSinceCreate++
            } else {
                FilamentStats.skipped.incrementAndGet()
            }
        } catch (t: Throwable) {
            FilamentStats.lastError = "render: ${t.javaClass.simpleName}: ${t.message}"
            NativeLog.log(TAG, "RENDER FAILED view #$id: $t")
        } finally {
            if (frameStarted) {
                try { r.endFrame() } catch (t: Throwable) {
                    NativeLog.log(TAG, "endFrame failed view #$id: $t")
                }
            }
        }
        lastRenderAt = SystemClock.elapsedRealtime()
        FilamentStats.lastFrameMs = (SystemClock.elapsedRealtimeNanos() - t0) / 1_000_000f
    }

    fun dispose() {
        if (disposed) return
        cancelPendingModelLoad()
        disposed = true
        host.handler.removeCallbacks(renderRunnable)
        if (!unloadModel()) {
            try { engine.flushAndWait() } catch (_: Throwable) {}
            unloadModel()
        }
        try { resourceLoader?.destroy() } catch (t: Throwable) { NativeLog.log(TAG, "dispose resource loader #$id: $t") }
        resourceLoader = null
        try { scene?.let { host.removeLights(it) } } catch (t: Throwable) { NativeLog.log(TAG, "dispose lights #$id: $t") }
        try { swapChain?.let { engine.destroySwapChain(it) } } catch (t: Throwable) { NativeLog.log(TAG, "dispose swapchain #$id: $t") }
        swapChain = null
        try { engine.flushAndWait() } catch (t: Throwable) { NativeLog.log(TAG, "dispose flush #$id: $t") }
        try { view?.let { engine.destroyView(it) } } catch (t: Throwable) { NativeLog.log(TAG, "dispose view #$id: $t") }
        try { scene?.let { engine.destroyScene(it) } } catch (t: Throwable) { NativeLog.log(TAG, "dispose scene #$id: $t") }
        try { renderer?.let { engine.destroyRenderer(it) } } catch (t: Throwable) { NativeLog.log(TAG, "dispose renderer #$id: $t") }
        try { camera?.let { engine.destroyCameraComponent(cameraEntity) } } catch (t: Throwable) { NativeLog.log(TAG, "dispose camera #$id: $t") }
        try { if (cameraEntity != 0) EntityManager.get().destroy(cameraEntity) } catch (t: Throwable) { NativeLog.log(TAG, "dispose camera entity #$id: $t") }
        try { engine.flushAndWait() } catch (t: Throwable) { NativeLog.log(TAG, "dispose final flush #$id: $t") }
        swapChain = null; view = null; scene = null; renderer = null; camera = null
        surface = null
        try { producer.setCallback(null) } catch (_: Throwable) {}
        try { producer.release() } catch (_: Throwable) {}
        FilamentStats.views.decrementAndGet()
        NativeLog.log(TAG, "view #$id disposed (frames rendered for it: $framesSinceCreate)")
    }

    companion object {
        const val FOV_DEGREES = 32.0
        // کره‌ای به شعاع ۱ باید کامل در کادر بنشیند، با کمی حاشیه.
        val CAMERA_DISTANCE: Double = 1.0 / sin(Math.toRadians(FOV_DEGREES / 2.0)) * 1.04
        const val MIN_FRAME_GAP_MS = 45L // ~22fps
    }
}

/**
 * MethodChannel "ir.abtin.abtinmaps/filament_car":
 *   create{asset,width,height,theta,phi} → textureId
 *   update{id,theta,phi} · resize{id,width,height} · model{id,asset} · dispose{id} · status
 */
class FilamentCarPlugin(
    private val context: Context,
    private val textures: TextureRegistry,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "ir.abtin.abtinmaps/filament_car")
    private var host: FilamentHost? = null
    private val views = HashMap<Long, CarView>() // فقط روی نخ اصلی دست‌کاری می‌شود

    init {
        channel.setMethodCallHandler(this)
    }

    private fun ensureHost(): FilamentHost = host ?: FilamentHost().also { host = it }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Filament channel must be handled on Android main thread" }
        when (call.method) {
            "create" -> {
                val asset = call.argument<String>("asset")
                val w = call.argument<Int>("width") ?: 0
                val h = call.argument<Int>("height") ?: 0
                if (asset == null || w <= 0 || h <= 0) {
                    result.error("bad_args", "asset/width/height required", null)
                    return
                }
                val rawTheta = call.argument<Number>("theta")?.toDouble() ?: 180.0
                val rawPhi = call.argument<Number>("phi")?.toDouble() ?: 60.0
                val theta = if (rawTheta.isFinite()) ((rawTheta % 360.0) + 360.0) % 360.0 else 180.0
                val phi = if (rawPhi.isFinite()) rawPhi.coerceIn(2.0, 78.0) else 60.0
                val hst = ensureHost()
                val producer = try {
                    textures.createSurfaceProducer()
                } catch (t: Throwable) {
                    result.error("texture", t.toString(), null)
                    return
                }
                hst.handler.post {
                    if (!hst.init()) {
                        producer.release()
                        if (host === hst) host = null
                        postResult { result.error("engine", FilamentStats.lastError ?: "engine init failed", null) }
                        return@post
                    }
                    val cv = CarView(hst, producer, context.applicationContext, asset, w, h, theta, phi)
                    try {
                        cv.create()
                        views[cv.id] = cv
                        postResult { result.success(cv.id) }
                    } catch (t: Throwable) {
                        FilamentStats.lastError = "create: ${t.javaClass.simpleName}: ${t.message}"
                        NativeLog.log(TAG, "CREATE FAILED: $t\n${t.stackTraceToString().take(1200)}")
                        try { cv.dispose() } catch (_: Throwable) {}
                        if (views.isEmpty()) {
                            hst.shutdown()
                            if (host === hst) host = null
                        }
                        postResult { result.error("create", t.toString(), null) }
                    }
                }
            }
            "viewReady" -> {
                val id = call.argument<Number>("id")?.toLong()
                result.success(if (id != null) views[id]?.isModelViewReady() == true else false)
            }
            "viewState" -> {
                val id = call.argument<Number>("id")?.toLong()
                result.success(if (id != null) views[id]?.modelState() ?: "failed" else "failed")
            }
            "update" -> {
                val id = (call.argument<Number>("id") ?: return result.success(null)).toLong()
                val rawT = call.argument<Number>("theta")?.toDouble() ?: 180.0
                val rawP = call.argument<Number>("phi")?.toDouble() ?: 60.0
                val t = if (rawT.isFinite()) rawT else 180.0
                val p = if (rawP.isFinite()) rawP else 60.0
                host?.handler?.post {
                    try { views[id]?.setOrbit(t, p) } catch (e: Throwable) {
                        FilamentStats.lastError = "update: ${e.javaClass.simpleName}: ${e.message}"
                        NativeLog.log(TAG, "UPDATE FAILED view #$id: $e")
                    }
                }
                result.success(null)
            }
            "resize" -> {
                val id = (call.argument<Number>("id") ?: return result.success(null)).toLong()
                val w = call.argument<Int>("width") ?: 0
                val h = call.argument<Int>("height") ?: 0
                if (w > 0 && h > 0) host?.handler?.post {
                    try { views[id]?.resize(w, h) } catch (e: Throwable) {
                        FilamentStats.lastError = "resize: ${e.javaClass.simpleName}: ${e.message}"
                        NativeLog.log(TAG, "RESIZE FAILED view #$id: $e")
                    }
                }
                result.success(null)
            }
            "model" -> {
                val id = (call.argument<Number>("id") ?: return result.success(null)).toLong()
                val a = call.argument<String>("asset")
                if (a != null) host?.handler?.post {
                    try { views[id]?.setModel(a) } catch (e: Throwable) {
                        FilamentStats.lastError = "model switch: ${e.javaClass.simpleName}: ${e.message}"
                        NativeLog.log(TAG, "MODEL SWITCH FAILED view #$id: $e")
                    }
                }
                result.success(null)
            }
            "dispose" -> {
                val id = (call.argument<Number>("id") ?: return result.success(null)).toLong()
                val hst = host
                if (hst == null) {
                    result.success(null)
                } else {
                    hst.handler.post {
                        try {
                            views.remove(id)?.dispose()
                            if (views.isEmpty()) {
                                // آخرین نما بسته شد: Engine را هم آزاد کن (حافظهٔ GPU).
                                hst.shutdown()
                                if (host === hst) host = null
                            }
                        } catch (e: Throwable) {
                            FilamentStats.lastError = "dispose: ${e.javaClass.simpleName}: ${e.message}"
                            NativeLog.log(TAG, "DISPOSE FAILED view #$id: $e")
                        }
                    }
                    result.success(null)
                }
            }
            "status" -> result.success(FilamentStats.line())
            else -> result.notImplemented()
        }
    }

    private fun postResult(block: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        val hst = host ?: return
        host = null
        hst.handler.post {
            for (v in views.values) v.dispose()
            views.clear()
            hst.shutdown()
        }
    }
}
