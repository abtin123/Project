package ir.avash.maps

import android.content.Intent
import android.content.ComponentName
import android.content.Context
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.os.BatteryManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "ir.avash.maps/device_battery"
    private var locationBridge: LocationBridge? = null
    private var debugBridge: DebugBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        locationBridge?.dispose()
        locationBridge = LocationBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        debugBridge = DebugBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        NativeDebug.log("engine", "Flutter engine configured")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ir.avash.maps/nav_service")
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
                            NativeDebug.log("svc", "start failed: $t")
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        try { stopService(Intent(this, NavigationService::class.java)) } catch (_: Throwable) {}
                        result.success(null)
                    }
                    "requestBatteryExemptionOnce" -> result.success(requestBatteryExemptionOnce())
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

    /** Shows the system "ignore battery optimizations" dialog, at most once per install. */
    private fun requestBatteryExemptionOnce(): Boolean {
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(packageName)) return true
            val prefs = getSharedPreferences("avash_nav", Context.MODE_PRIVATE)
            if (prefs.getBoolean("battery_asked", false)) return false
            prefs.edit().putBoolean("battery_asked", true).apply()
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName"))
            )
            false
        } catch (t: Throwable) {
            NativeDebug.log("svc", "battery exemption failed: $t")
            false
        }
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
