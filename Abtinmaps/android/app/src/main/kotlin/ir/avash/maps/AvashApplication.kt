package ir.avash.maps

import android.app.Application

class AvashApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        NativeDebug.init(this)
    }
}
