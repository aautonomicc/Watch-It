package io.github.aautonomicc.watchit

import android.app.Application
import android.content.Context
import android.os.Build
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

// Installs the Java crash recorder before any activity/plugin code
// runs. Android's ApplicationExitInfo names a Java crash (REASON_CRASH)
// but attaches no stack trace to it — on a device with no adb access
// the exception itself is unrecoverable. So the default uncaught-
// exception handler persists the full stack to a file here; the
// "Why did the app close?" page attaches it to the matching OS record.
class WatchItApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        JavaCrashRecorder.install(this)
    }
}

object JavaCrashRecorder {
    private const val DIR_NAME = "crash_logs"
    private const val KEEP = 5
    private const val MAX_CHARS = 64 * 1024

    fun install(app: Application) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                record(app, thread, throwable)
            } catch (_: Throwable) {
                // Best effort only — never mask the crash itself.
            }
            // Chain to the system handler so the process still dies and
            // the OS still writes its REASON_CRASH exit record.
            previous?.uncaughtException(thread, throwable)
                ?: run {
                    android.os.Process.killProcess(android.os.Process.myPid())
                    System.exit(10)
                }
        }
    }

    private fun dir(context: Context) = File(context.filesDir, DIR_NAME)

    private fun record(app: Application, thread: Thread, e: Throwable) {
        val d = dir(app)
        d.mkdirs()
        val ts = System.currentTimeMillis()
        val text = try {
            val sw = StringWriter()
            sw.append("app: ${versionOf(app)}, sdk ${Build.VERSION.SDK_INT}, ")
            sw.append("${Build.MANUFACTURER} ${Build.MODEL}\n")
            sw.append("thread: ${thread.name}\n")
            e.printStackTrace(PrintWriter(sw))
            sw.toString()
        } catch (_: Throwable) {
            // OutOfMemoryError etc. while building the full trace — a
            // one-line summary still names the exception class.
            "thread: ${thread.name}\n${e.javaClass.name}: ${e.message}"
        }
        File(d, "java_$ts.txt").writeText(text.take(MAX_CHARS))
        prune(d)
    }

    private fun versionOf(context: Context): String = try {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= 28) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        "${info.versionName} ($code)"
    } catch (_: Throwable) {
        "unknown"
    }

    private fun prune(d: File) {
        d.listFiles { f -> f.name.startsWith("java_") }
            ?.sortedByDescending { it.name }
            ?.drop(KEEP)
            ?.forEach { it.delete() }
    }

    // Saved crashes as (timestampMs, trace), newest first.
    fun crashes(context: Context): List<Pair<Long, String>> =
        dir(context).listFiles { f -> f.name.startsWith("java_") }
            ?.mapNotNull { f ->
                val ts = f.name.removePrefix("java_").removeSuffix(".txt")
                    .toLongOrNull() ?: return@mapNotNull null
                try {
                    ts to f.readText()
                } catch (_: Throwable) {
                    null
                }
            }
            ?.sortedByDescending { it.first }
            ?: emptyList()
}
