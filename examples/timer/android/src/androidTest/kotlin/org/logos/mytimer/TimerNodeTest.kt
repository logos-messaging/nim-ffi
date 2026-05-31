package org.logos.mytimer

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

// Instrumented test — runs on a device/emulator (the .so files are device code).
//   ./gradlew connectedAndroidTest
@RunWith(AndroidJUnit4::class)
class TimerNodeTest {
    @Test
    fun createVersionEcho() {
        TimerNode("android-demo").use { node ->
            assertEquals("nim-timer v0.1.0", node.version())
            val r = node.echo("hello from Kotlin", delayMs = 2)
            assertEquals("hello from Kotlin", r.echoed)
            assertEquals("android-demo", r.timerName) // lib state round-tripped
        }
    }
}
