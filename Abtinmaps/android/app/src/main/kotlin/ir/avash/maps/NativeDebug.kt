package ir.avash.maps

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.Process
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Native-side flight recorder: uncaught exceptions, main-thread stalls (ANR
 * precursors), lifecycle, memory pressure and the reason the previous process
 * died (ApplicationExitInfo). Everything goes to <externalFiles>/debug/native.log
 * so it can be read from inside the app, from a file manager or with adb.
 */
object NativeDebug {
    private const val MAX_BYTES = 768 * 1024L
    private var dir: File? = null
    private var logFile: File? = null
    private val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    @Volatile private var lastMainBeat = System.currentTimeMillis()
    @Volatile private var stallReported = false

    val logDir: File? get() = dir
    val file: File? get() = logFile

    @Synchronized
    fun log(tag: String, msg: String) {
        val f = logFile ?: return
        try {
            if (f.length() > MAX_BYTES) {
                val old = File(f.parentFile, "native.1.log")
                old.delete()
                f.renameTo(old)
            }
            f.appendText("${fmt.format(Date())} [$tag] $msg\n")
        } catch (_: Throwable) {
        }
    }

    fun init(app: Application) {
        val base = app.getExternalFilesDir(null) ?: app.filesDir
        val d = File(base, "debug")
        d.mkdirs()
        dir = d
        logFile = File(d, "native.log")
        log("proc", "START pid=${Process.myPid()} sdk=${Build.VERSION.SDK_INT} " +
            "device=${Build.MANUFACTURER} ${Build.MODEL} abi=${Build.SUPPORTED_ABIS.joinToString()}")
        log("mem", memoryLine(app))
        recordPreviousExits(app)
        installCrashHandler()
        installLifecycle(app)
        startMainThreadWatchdog()
        startFdWatch()
    }

    fun memoryLine(ctx: Context): String {
        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        val dm = Debug.MemoryInfo()
        Debug.getMemoryInfo(dm)
        val rt = Runtime.getRuntime()
        val fds = try { File("/proc/self/fd").list()?.size ?: -1 } catch (_: Throwable) { -1 }
        val threads = try { Thread.getAllStackTraces().size } catch (_: Throwable) { -1 }
        return "pssMB=${dm.totalPss / 1024} javaMB=${(rt.totalMemory() - rt.freeMemory()) / 1048576}/" +
            "${rt.maxMemory() / 1048576} nativeHeapMB=${Debug.getNativeHeapAllocatedSize() / 1048576} " +
            "availMB=${mi.availMem / 1048576} lowMem=${mi.lowMemory} thresholdMB=${mi.threshold / 1048576} " +
            "fds=$fds threads=$threads"
    }


    /** Groups open file descriptors by kind/target so a leak shows what it is made of. */
    fun fdBreakdown(): String {
        val names = try { File("/proc/self/fd").list() } catch (_: Throwable) { null }
            ?: return "fd list unavailable"
        val groups = HashMap<String, Int>()
        for (n in names) {
            val t = try { android.system.Os.readlink("/proc/self/fd/$n") } catch (_: Throwable) { continue }
            val key = when {
                t.startsWith("socket:") -> "socket"
                t.startsWith("pipe:") -> "pipe"
                t.startsWith("anon_inode:") -> t
                t.startsWith("/dev/") -> t
                else -> t.substringBeforeLast('/', t)
            }
            groups[key] = (groups[key] ?: 0) + 1
        }
        return "total=${names.size} " + groups.entries.sortedByDescending { it.value }
            .take(10).joinToString(" | ") { "${it.value}x ${it.key}" }
    }

    /** Logs an fd breakdown when the count is high (Android's usual limit is 1024). */
    private fun startFdWatch() {
        Thread({
            var lastLoggedAt = 0L
            var lastLoggedCount = 0
            while (true) {
                try {
                    Thread.sleep(5000)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                val count = try { File("/proc/self/fd").list()?.size ?: 0 } catch (_: Throwable) { 0 }
                val now = System.currentTimeMillis()
                if (count >= 700 && (count >= lastLoggedCount + 100 || now - lastLoggedAt > 60_000)) {
                    lastLoggedAt = now
                    lastLoggedCount = count
                    val tag = if (count >= 900) "fd-NEAR-LIMIT" else "fd"
                    log(tag, fdBreakdown())
                } else if (count < 600) {
                    lastLoggedCount = 0
                }
            }
        }, "avash-fd-watch").apply { isDaemon = true; start() }
    }

    private fun installCrashHandler() {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                val sw = java.io.StringWriter()
                e.printStackTrace(java.io.PrintWriter(sw))
                log("CRASH", "UNCAUGHT in thread '${t.name}': $sw")
                File(dir, "last_crash.txt").writeText(
                    "${fmt.format(Date())} thread=${t.name}\n$sw"
                )
            } catch (_: Throwable) {
            }
            prev?.uncaughtException(t, e)
        }
    }

    private fun installLifecycle(app: Application) {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            private fun l(a: Activity, s: String) = log("life", "${a.javaClass.simpleName} $s")
            override fun onActivityCreated(a: Activity, b: Bundle?) = l(a, "onCreate")
            override fun onActivityStarted(a: Activity) = l(a, "onStart")
            override fun onActivityResumed(a: Activity) = l(a, "onResume")
            override fun onActivityPaused(a: Activity) = l(a, "onPause")
            override fun onActivityStopped(a: Activity) = l(a, "onStop")
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) = l(a, "onSaveInstanceState")
            override fun onActivityDestroyed(a: Activity) =
                log("life", "${a.javaClass.simpleName} onDestroy finishing=${a.isFinishing}")
        })
        app.registerComponentCallbacks(object : ComponentCallbacks2 {
            override fun onTrimMemory(level: Int) {
                log("mem", "onTrimMemory level=$level (${trimName(level)}) ${memoryLine(app)}")
            }
            override fun onLowMemory() {
                log("mem", "onLowMemory! ${memoryLine(app)}")
            }
            override fun onConfigurationChanged(c: Configuration) {}
        })
    }

    private fun trimName(l: Int) = when (l) {
        ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE -> "RUNNING_MODERATE"
        ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW -> "RUNNING_LOW"
        ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL -> "RUNNING_CRITICAL"
        ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN -> "UI_HIDDEN"
        ComponentCallbacks2.TRIM_MEMORY_BACKGROUND -> "BACKGROUND"
        ComponentCallbacks2.TRIM_MEMORY_MODERATE -> "MODERATE"
        ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> "COMPLETE"
        else -> "?"
    }

    private fun startMainThreadWatchdog() {
        val main = Handler(Looper.getMainLooper())
        val beat = object : Runnable {
            override fun run() {
                if (stallReported) {
                    log("ANR?", "main thread recovered after " +
                        "${System.currentTimeMillis() - lastMainBeat} ms")
                    stallReported = false
                }
                lastMainBeat = System.currentTimeMillis()
                main.postDelayed(this, 1000)
            }
        }
        main.post(beat)
        Thread({
            while (true) {
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                val gap = System.currentTimeMillis() - lastMainBeat
                if (gap > 4000 && !stallReported) {
                    stallReported = true
                    val st = Looper.getMainLooper().thread.stackTrace.joinToString("\n    at ")
                    log("ANR?", "MAIN THREAD BLOCKED ${gap} ms. Main stack:\n    at $st")
                }
            }
        }, "avash-main-watchdog").apply { isDaemon = true; start() }
    }

    /** Why did the previous process die? (Android 11+) */
    private fun recordPreviousExits(app: Application) {
        if (Build.VERSION.SDK_INT < 30) {
            log("exit", "ApplicationExitInfo needs Android 11+ (this is SDK ${Build.VERSION.SDK_INT})")
            return
        }
        try {
            val am = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val prefs = app.getSharedPreferences("avash_debug", Context.MODE_PRIVATE)
            val lastTs = prefs.getLong("last_exit_ts", 0L)
            var maxTs = lastTs
            val list = am.getHistoricalProcessExitReasons(app.packageName, 0, 10)
            for (i in list.reversed()) {
                if (i.timestamp <= lastTs) continue
                maxTs = maxOf(maxTs, i.timestamp)
                log("exit", "PREVIOUS PROCESS ENDED: ${exitName(i.reason)} " +
                    "at=${fmt.format(Date(i.timestamp))} pid=${i.pid} status=${i.status} " +
                    "importance=${i.importance} pssKB=${i.pss} rssKB=${i.rss} desc='${i.description}'")
                if (i.reason == android.app.ApplicationExitInfo.REASON_ANR ||
                    i.reason == android.app.ApplicationExitInfo.REASON_CRASH_NATIVE
                ) {
                    try {
                        val txt = i.traceInputStream?.bufferedReader()?.use { it.readText().take(24000) }
                        if (!txt.isNullOrEmpty()) log("exit", "TRACE:\n$txt")
                    } catch (_: Throwable) {
                    }
                }
            }
            prefs.edit().putLong("last_exit_ts", maxTs).apply()
        } catch (t: Throwable) {
            log("exit", "failed to read exit info: $t")
        }
    }

    fun exitName(r: Int): String = if (Build.VERSION.SDK_INT >= 30) when (r) {
        android.app.ApplicationExitInfo.REASON_ANR -> "ANR (app not responding)"
        android.app.ApplicationExitInfo.REASON_CRASH -> "CRASH (Java/Kotlin exception)"
        android.app.ApplicationExitInfo.REASON_CRASH_NATIVE -> "NATIVE CRASH (C/C++ signal)"
        android.app.ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        android.app.ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        android.app.ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF (app called exit/finish)"
        android.app.ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
        android.app.ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        android.app.ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY (killed by system, out of RAM)"
        android.app.ApplicationExitInfo.REASON_OTHER -> "OTHER"
        android.app.ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        android.app.ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED (killed by signal, e.g. SIGKILL)"
        android.app.ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
        android.app.ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED (swiped away / force stop)"
        android.app.ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        else -> "reason=$r"
    } else "reason=$r"

    fun readTail(maxBytes: Int = 96 * 1024): String {
        val f = logFile ?: return ""
        return try {
            val len = f.length()
            if (len <= maxBytes) f.readText()
            else java.io.RandomAccessFile(f, "r").use {
                it.seek(len - maxBytes)
                val b = ByteArray(maxBytes)
                it.readFully(b)
                String(b)
            }
        } catch (t: Throwable) {
            "read error: $t"
        }
    }
}
