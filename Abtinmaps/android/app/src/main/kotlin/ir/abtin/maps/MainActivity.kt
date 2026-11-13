package ir.abtin.maps

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "ir.abtin.maps/device_battery"
    private var locationBridge: LocationBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        locationBridge?.dispose()
        locationBridge = LocationBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
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
}
