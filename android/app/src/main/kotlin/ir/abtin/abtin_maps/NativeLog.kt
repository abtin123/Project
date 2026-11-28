package ir.abtin.abtin_maps

import android.util.Log

/** Minimal system logger for genuine native failures; no in-app recorder or monitoring. */
object NativeLog {
    fun log(tag: String, msg: String) {
        Log.w("AbtinMaps/${tag.take(32)}", msg.take(3000))
    }
}
