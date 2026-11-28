package ir.abtin.abtin_maps

import android.content.Intent
import android.content.ComponentName
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.os.BatteryManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "ir.abtin.abtin_maps/device_battery"
    private var locationBridge: LocationBridge? = null
    private var filamentCar: FilamentCarPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        locationBridge?.dispose()
        locationBridge = LocationBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // خودروی سه‌بعدی: Filament بومی (Kotlin)، بدون WebView و بدون پکیج فلاتر.
        filamentCar?.dispose()
        filamentCar = FilamentCarPlugin(
            applicationContext,
            flutterEngine.renderer,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        NativeLog.log("engine", "Flutter engine configured")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ir.abtin.abtin_maps/nav_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            val i = Intent(this, NavigationService::class.java)
                                .putExtra(NavigationService.EXTRA_TITLE, call.argument<String>("title"))
                                .putExtra(NavigationService.EXTRA_TEXT, call.argument<String>("text"))
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                            result.success(true)
                        } catch (t: Throwable) {
                            NativeLog.log("svc", "start failed: $t")
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        try { stopService(Intent(this, NavigationService::class.java)) } catch (_: Throwable) {}
                        result.success(null)
                    }
                    "openAutostart" -> result.success(openAutostart())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "batteryLevel" -> result.success(readBatteryLevel())
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        locationBridge?.dispose()
        locationBridge = null
        filamentCar?.dispose()
        filamentCar = null
        super.onDestroy()
    }

    private fun readBatteryLevel(): Int {
        val intent = registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        if (level < 0 || scale <= 0) return -1
        return ((level * 100f) / scale).toInt().coerceIn(0, 100)
    }

    /** Opens the Xiaomi/MIUI autostart page, or the app's settings page elsewhere. */
    private fun openAutostart(): Boolean {
        return try {
            startActivity(
                Intent().setComponent(
                    ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity"
                    )
                )
            )
            true
        } catch (_: Throwable) {
            try {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        .setData(Uri.parse("package:$packageName"))
                )
                true
            } catch (_: Throwable) {
                false
            }
        }
    }
}
