package org.logos.mytimer

/** Typed result of [TimerNode.echo] — mirrors the library's EchoResponse. */
data class EchoResult(val echoed: String, val timerName: String)

/**
 * Idiomatic Kotlin wrapper over the timer library's native C ABI, bridged through
 * JNI (see jni/my_timer_jni.c). Each call blocks until the library's FFI-thread
 * callback fires, so these methods are simple and synchronous.
 *
 * Call [close] (or use Kotlin's `use { }`) to tear the context down.
 */
class TimerNode(name: String) : AutoCloseable {
    private val ctx: Long = nativeCreate(name)

    fun version(): String = nativeVersion(ctx)

    fun echo(message: String, delayMs: Long = 0): EchoResult {
        val a = nativeEcho(ctx, message, delayMs)
        return EchoResult(a[0], a[1])
    }

    override fun close() = nativeDestroy(ctx)

    private external fun nativeCreate(name: String): Long
    private external fun nativeVersion(ctx: Long): String
    private external fun nativeEcho(ctx: Long, message: String, delayMs: Long): Array<String>
    private external fun nativeDestroy(ctx: Long)

    companion object {
        init {
            // libmy_timer.so (the Nim library) is a NEEDED dependency of the JNI
            // shim, but load it explicitly first so the linker finds it.
            System.loadLibrary("my_timer")
            System.loadLibrary("my_timer_jni")
        }
    }
}
