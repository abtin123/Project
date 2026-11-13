package ir.abtin.maps

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.GnssStatus
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * GPS + Network (Wi-Fi / cell tower) location source without Google Play Services.
 * GPS fixes and network fixes are delivered separately, tagged by source, so the
 * Dart-side Kalman filter can weight them by their own accuracy.
 */
class LocationBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var running = false
    private var navigation = false
    private var gnssCallback: GnssStatus.Callback? = null

    private val gpsListener = Listener("gps")
    private val netListener = Listener("network")

    init {
        MethodChannel(messenger, "ir.abtin.maps/location").setMethodCallHandler(this)
        EventChannel(messenger, "ir.abtin.maps/location_events").setStreamHandler(this)
    }

    private inner class Listener(private val source: String) : LocationListener {
        override fun onLocationChanged(location: Location) {
            emit(toMap(location, source, false))
        }

        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

        override fun onProviderEnabled(provider: String) {
            emitProviders()
        }

        override fun onProviderDisabled(provider: String) {
            emitProviders()
        }
    }

    private fun hasFine() =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasCoarse() =
        context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun enabled(provider: String): Boolean =
        try {
            lm.isProviderEnabled(provider)
        } catch (_: Exception) {
            false
        }

    private fun emit(map: Map<String, Any?>) {
        sink?.success(map)
    }

    private fun emitProviders() {
        emit(
            hashMapOf(
                "type" to "provider",
                "gps" to enabled(LocationManager.GPS_PROVIDER),
                "network" to enabled(LocationManager.NETWORK_PROVIDER),
            )
        )
    }

    private fun toMap(l: Location, source: String, cached: Boolean): HashMap<String, Any?> {
        val m = HashMap<String, Any?>()
        m["type"] = "fix"
        m["lat"] = l.latitude
        m["lng"] = l.longitude
        m["acc"] = if (l.hasAccuracy()) l.accuracy.toDouble() else -1.0
        m["speed"] = if (l.hasSpeed()) l.speed.toDouble() else null
        m["bearing"] = if (l.hasBearing()) l.bearing.toDouble() else null
        m["alt"] = if (l.hasAltitude()) l.altitude else null
        if (Build.VERSION.SDK_INT >= 26) {
            if (l.hasSpeedAccuracy()) m["speedAcc"] = l.speedAccuracyMetersPerSecond.toDouble()
            if (l.hasBearingAccuracy()) m["bearingAcc"] = l.bearingAccuracyDegrees.toDouble()
        }
        m["time"] = l.time
        m["elapsedMs"] = l.elapsedRealtimeNanos / 1_000_000L
        m["source"] = source
        m["cached"] = cached
        @Suppress("DEPRECATION")
        m["mock"] = if (Build.VERSION.SDK_INT >= 31) l.isMock else l.isFromMockProvider
        return m
    }

    @SuppressLint("MissingPermission")
    private fun startUpdates() {
        stopUpdates()
        val fine = hasFine()
        if (!fine && !hasCoarse()) return
        running = true
        val netInterval = if (navigation) 4000L else 8000L
        try {
            if (fine && enabled(LocationManager.GPS_PROVIDER)) {
                lm.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER, 1000L, 0f, gpsListener, Looper.getMainLooper()
                )
            }
        } catch (_: Exception) {
        }
        try {
            if (enabled(LocationManager.NETWORK_PROVIDER)) {
                lm.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER, netInterval, 0f, netListener, Looper.getMainLooper()
                )
            }
        } catch (_: Exception) {
        }
        if (fine) {
            try {
                val cb = object : GnssStatus.Callback() {
                    override fun onSatelliteStatusChanged(status: GnssStatus) {
                        var used = 0
                        var cn0 = 0.0
                        for (i in 0 until status.satelliteCount) {
                            if (status.usedInFix(i)) {
                                used++
                                cn0 += status.getCn0DbHz(i)
                            }
                        }
                        emit(
                            hashMapOf(
                                "type" to "gnss",
                                "used" to used,
                                "visible" to status.satelliteCount,
                                "cn0" to (if (used > 0) cn0 / used else 0.0),
                            )
                        )
                    }
                }
                gnssCallback = cb
                lm.registerGnssStatusCallback(cb, main)
            } catch (_: Exception) {
            }
        }
        emitProviders()
        lastKnownMap()?.let { emit(it) }
    }

    @SuppressLint("MissingPermission")
    private fun stopUpdates() {
        running = false
        try {
            lm.removeUpdates(gpsListener)
            lm.removeUpdates(netListener)
        } catch (_: Exception) {
        }
        gnssCallback?.let {
            try {
                lm.unregisterGnssStatusCallback(it)
            } catch (_: Exception) {
            }
        }
        gnssCallback = null
    }

    @SuppressLint("MissingPermission")
    private fun lastKnownMap(): HashMap<String, Any?>? {
        if (!hasFine() && !hasCoarse()) return null
        var best: Location? = null
        var bestSource = "network"
        for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)) {
            val l = try {
                lm.getLastKnownLocation(p)
            } catch (_: Exception) {
                null
            } ?: continue
            if (best == null || l.elapsedRealtimeNanos > best.elapsedRealtimeNanos) {
                best = l
                bestSource = if (p == LocationManager.GPS_PROVIDER) "gps" else "network"
            }
        }
        val b = best ?: return null
        val ageMs = (SystemClock.elapsedRealtimeNanos() - b.elapsedRealtimeNanos) / 1_000_000L
        if (ageMs > 24L * 3600L * 1000L) return null
        return toMap(b, bestSource, true)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permission" -> result.success(hashMapOf("fine" to hasFine(), "coarse" to hasCoarse()))
            "serviceEnabled" -> result.success(
                enabled(LocationManager.GPS_PROVIDER) || enabled(LocationManager.NETWORK_PROVIDER)
            )
            "start" -> {
                navigation = call.argument<Boolean>("navigation") ?: false
                startUpdates()
                result.success(running)
            }
            "setNavigation" -> {
                val next = call.argument<Boolean>("navigation") ?: false
                if (next != navigation) {
                    navigation = next
                    if (running) startUpdates()
                }
                result.success(null)
            }
            "stop" -> {
                stopUpdates()
                result.success(null)
            }
            "lastKnown" -> result.success(lastKnownMap())
            "openSettings" -> {
                try {
                    context.startActivity(
                        Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                } catch (_: Exception) {
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun dispose() {
        stopUpdates()
        sink = null
    }
}
