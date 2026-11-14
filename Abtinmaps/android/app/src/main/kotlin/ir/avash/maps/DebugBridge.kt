package ir.avash.maps

import android.app.ActivityManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** MethodChannel "ir.avash.maps/debug": exposes the native flight recorder to Dart. */
class DebugBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, "ir.avash.maps/debug").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "snapshot" -> result.success(snapshot())
            "memory" -> result.success(NativeDebug.memoryLine(context))
            "nativeLog" -> result.success(NativeDebug.readTail())
            "lastCrash" -> result.success(
                try { File(NativeDebug.logDir, "last_crash.txt").takeIf { it.exists() }?.readText() } catch (_: Throwable) { null }
            )
            "clearNativeLog" -> {
                try {
                    NativeDebug.file?.writeText("")
                    File(NativeDebug.logDir, "last_crash.txt").delete()
                } catch (_: Throwable) {
                }
                result.success(null)
            }
            "log" -> {
                NativeDebug.log(call.argument<String>("tag") ?: "dart", call.argument<String>("msg") ?: "")
                result.success(null)
            }
            "logDir" -> result.success(NativeDebug.logDir?.absolutePath)
            "logcat" -> {
                val n = call.argument<Int>("lines") ?: 1200
                Thread {
                    val out = runLogcat(n)
                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(out) }
                }.start()
            }
            "openBatterySettings" -> {
                try {
                    context.startActivity(
                        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                } catch (_: Throwable) {
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun runLogcat(lines: Int): String {
        val attempts = listOf(
            arrayOf("logcat", "-d", "-v", "threadtime", "-b", "main,system,crash", "-t", lines.toString()),
            arrayOf("logcat", "-d", "-v", "threadtime", "-t", lines.toString()),
        )
        for (cmd in attempts) {
            try {
                val p = Runtime.getRuntime().exec(cmd)
                val text = p.inputStream.bufferedReader().use { it.readText() }
                p.destroy()
                if (text.isNotBlank()) return text
            } catch (_: Throwable) {
            }
        }
        return "(logcat not readable on this device)"
    }

    private fun snapshot(): String {
        val sb = StringBuilder()
        sb.appendLine("device: ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE})")
        sb.appendLine("android: ${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT} patch=${if (Build.VERSION.SDK_INT >= 23) Build.VERSION.SECURITY_PATCH else "?"}")
        sb.appendLine("abi: ${Build.SUPPORTED_ABIS.joinToString()}")
        sb.appendLine("pid: ${android.os.Process.myPid()}")
        sb.appendLine("memory: ${NativeDebug.memoryLine(context)}")
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            sb.appendLine("lowRamDevice: ${am.isLowRamDevice}  memoryClassMB: ${am.memoryClass}  largeMemoryClassMB: ${am.largeMemoryClass}")
            if (Build.VERSION.SDK_INT >= 28) sb.appendLine("backgroundRestricted: ${am.isBackgroundRestricted}")
        } catch (_: Throwable) {
        }
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            sb.appendLine("ignoringBatteryOptimizations: ${pm.isIgnoringBatteryOptimizations(context.packageName)}")
            sb.appendLine("powerSaveMode: ${pm.isPowerSaveMode}  deviceIdle: ${if (Build.VERSION.SDK_INT >= 23) pm.isDeviceIdleMode else "?"}")
        } catch (_: Throwable) {
        }
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                val us = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
                val b = us.appStandbyBucket
                val name = when (b) {
                    UsageStatsManager.STANDBY_BUCKET_ACTIVE -> "ACTIVE"
                    UsageStatsManager.STANDBY_BUCKET_WORKING_SET -> "WORKING_SET"
                    UsageStatsManager.STANDBY_BUCKET_FREQUENT -> "FREQUENT"
                    UsageStatsManager.STANDBY_BUCKET_RARE -> "RARE"
                    UsageStatsManager.STANDBY_BUCKET_RESTRICTED -> "RESTRICTED"
                    else -> "$b"
                }
                sb.appendLine("standbyBucket: $name")
            } catch (_: Throwable) {
            }
        }
        sb.appendLine("logDir: ${NativeDebug.logDir?.absolutePath}")
        return sb.toString()
    }
}
