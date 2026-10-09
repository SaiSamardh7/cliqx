package com.saisamardh.cliqx

import com.saisamardh.cliqx.bridge.BridgeMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The page is untrusted input, so these cover what a hostile page sends, not
 * only what the agent sends. Mirrors the posture of the Swift tests in
 * `ios/Tests/CleanPlayerTests`.
 *
 * Robolectric because `BridgeMessage` decodes with `org.json`, which is stubbed
 * out in the plain JVM unit-test classpath.
 */
@RunWith(RobolectricTestRunner::class)
class BridgeMessageTest {

    private fun decode(raw: String) = BridgeMessage.decode(raw).first

    @Test
    fun `decodes a ready message and its frame id`() {
        val (message, frame) = BridgeMessage.decode(
            """{"v":1,"type":"ready","fid":"abc-123"}""",
        )
        assertEquals(BridgeMessage.Ready, message)
        assertEquals("abc-123", frame)
    }

    @Test
    fun `rejects a payload that is not an object`() {
        assertThrows(BridgeMessage.ValidationError.MalformedPayload::class.java) {
            decode("[1,2,3]")
        }
    }

    @Test
    fun `rejects a missing version`() {
        assertThrows(BridgeMessage.ValidationError.UnsupportedVersion::class.java) {
            decode("""{"type":"ready"}""")
        }
    }

    @Test
    fun `rejects a future version rather than guessing at it`() {
        assertThrows(BridgeMessage.ValidationError.UnsupportedVersion::class.java) {
            decode("""{"v":2,"type":"ready"}""")
        }
    }

    @Test
    fun `rejects an unknown type`() {
        assertThrows(BridgeMessage.ValidationError.UnknownType::class.java) {
            decode("""{"v":1,"type":"exfiltrate"}""")
        }
    }

    @Test
    fun `rejects a non-finite number`() {
        assertThrows(BridgeMessage.ValidationError.NumberOutOfRange::class.java) {
            decode("""{"v":1,"type":"blocked","count":"NaN"}""")
        }
    }

    @Test
    fun `rejects a negative count`() {
        assertThrows(BridgeMessage.ValidationError.NumberOutOfRange::class.java) {
            decode("""{"v":1,"type":"blocked","count":-5}""")
        }
    }

    @Test
    fun `rejects a time beyond the accepted range`() {
        assertThrows(BridgeMessage.ValidationError.NumberOutOfRange::class.java) {
            decode(
                """{"v":1,"type":"time","at":1e12,"duration":1,""" +
                    """"live":false,"buffered":0,"rate":1}""",
            )
        }
    }

    @Test
    fun `rejects an over-long string`() {
        val long = "x".repeat(BridgeMessage.MAX_STRING_LENGTH + 1)
        assertThrows(BridgeMessage.ValidationError.StringTooLong::class.java) {
            decode(
                """{"v":1,"type":"video","height":10,"width":10,""" +
                    """"fit":"$long","sources":[]}""",
            )
        }
    }

    @Test
    fun `decodes a media error into the app's own wording`() {
        val message = decode("""{"v":1,"type":"mediaError","reason":"drm"}""")
        val reason = (message as BridgeMessage.MediaError).reason
        assertEquals(BridgeMessage.MediaErrorReason.DRM, reason)
        // The user-facing string comes from the app, never from the page.
        assertTrue(reason.message.contains("DRM"))
    }

    @Test
    fun `rejects a media error reason outside the closed set`() {
        assertThrows(BridgeMessage.ValidationError.UnknownType::class.java) {
            decode("""{"v":1,"type":"mediaError","reason":"<script>"}""")
        }
    }

    @Test
    fun `decodes video sources`() {
        val message = decode(
            """{"v":1,"type":"video","height":720,"width":1280,"fit":"contain",""" +
                """"sources":[{"index":0,"label":"1080p","active":true}]}""",
        )
        val info = (message as BridgeMessage.Video).info
        assertEquals(720, info.height)
        assertEquals(1, info.sources.size)
        assertEquals("1080p", info.sources[0].label)
        assertTrue(info.sources[0].active)
    }
}
