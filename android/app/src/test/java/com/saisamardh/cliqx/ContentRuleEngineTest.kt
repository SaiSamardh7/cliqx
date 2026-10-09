package com.saisamardh.cliqx

import com.saisamardh.cliqx.blocking.ContentRuleEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Robolectric for `org.json` and `android.net.Uri`. */
@RunWith(RobolectricTestRunner::class)
class ContentRuleEngineTest {

    private val thirdPartyBlock = """
    [{"trigger":{"url-filter":"^https?://([^/]*\\.)?doubleclick\\.net/",
       "load-type":["third-party"]},"action":{"type":"block"}}]
    """.trimIndent()

    @Test
    fun `blocks a third-party ad host`() {
        val engine = ContentRuleEngine.from(thirdPartyBlock)
        assertTrue(
            engine.shouldBlock(
                "https://ad.doubleclick.net/pixel.gif",
                documentHost = "news.example.com",
            ),
        )
        assertEquals(1, engine.blockedCount)
    }

    @Test
    fun `leaves an unrelated request alone`() {
        val engine = ContentRuleEngine.from(thirdPartyBlock)
        assertFalse(
            engine.shouldBlock(
                "https://news.example.com/app.js",
                documentHost = "news.example.com",
            ),
        )
        assertEquals(0, engine.blockedCount)
    }

    @Test
    fun `a third-party rule does not fire first-party`() {
        val engine = ContentRuleEngine.from(thirdPartyBlock)
        assertFalse(
            engine.shouldBlock(
                "https://ad.doubleclick.net/pixel.gif",
                documentHost = "www.doubleclick.net",
            ),
        )
    }

    @Test
    fun `an unknown document host counts as first-party so nothing over-blocks`() {
        val engine = ContentRuleEngine.from(thirdPartyBlock)
        assertFalse(
            engine.shouldBlock("https://ad.doubleclick.net/p.gif", documentHost = null),
        )
    }

    @Test
    fun `a subdomain of the document is first-party`() {
        assertFalse(
            ContentRuleEngine.isThirdParty("cdn.example.com", "www.example.com"),
        )
    }

    @Test
    fun `a later ignore-previous-rules undoes an earlier block`() {
        val engine = ContentRuleEngine.from(
            """
            [{"trigger":{"url-filter":"tracker\\.js"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"tracker\\.js","if-domain":["allowed.com"]},
              "action":{"type":"ignore-previous-rules"}}]
            """.trimIndent(),
        )
        assertTrue(engine.shouldBlock("https://x.com/tracker.js", "other.com"))
        assertFalse(engine.shouldBlock("https://x.com/tracker.js", "allowed.com"))
    }

    @Test
    fun `an uncompilable rule is skipped instead of taking the list down`() {
        val engine = ContentRuleEngine.from(
            """
            [{"trigger":{"url-filter":"([unclosed"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"bad\\.example"},"action":{"type":"block"}}]
            """.trimIndent(),
        )
        assertTrue(engine.shouldBlock("https://bad.example/a.js", "site.com"))
    }

    @Test
    fun `unparseable json yields an engine that blocks nothing`() {
        val engine = ContentRuleEngine.from("not json")
        assertFalse(engine.shouldBlock("https://doubleclick.net/x", "a.com"))
    }

    @Test
    fun `css-display-none rules are left to the agent`() {
        val engine = ContentRuleEngine.from(
            """[{"trigger":{"url-filter":".*"},
                 "action":{"type":"css-display-none","selector":".ad"}}]""",
        )
        assertFalse(engine.shouldBlock("https://anything.com/x.js", "a.com"))
    }
}
