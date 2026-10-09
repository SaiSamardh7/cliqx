package com.saisamardh.cliqx

import android.os.Bundle
import android.util.Log
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.PlayerView
import com.saisamardh.cliqx.blocking.ContentRuleEngine
import com.saisamardh.cliqx.blocking.RuleEngine
import com.saisamardh.cliqx.browser.CliqxWebView
import com.saisamardh.cliqx.bridge.BridgeMessage
import com.saisamardh.cliqx.player.StreamPlayer

/**
 * Walking skeleton: proves the three unknowns and stubs the rest.
 *
 * Deliberately views rather than Compose — Compose is in the dependency set for
 * the real UI, but wrapping a WebView and a PlayerView in `AndroidView` adds a
 * layer between this and the two things under test. The browser chrome,
 * settings and player controls that `ios/Sources/CleanPlayer` builds in SwiftUI
 * are not here yet.
 */
// PlayerView is @UnstableApi, which is RequiresOptIn at ERROR level.
@OptIn(UnstableApi::class)
class MainActivity : ComponentActivity() {

    private lateinit var web: CliqxWebView
    private lateinit var streamPlayer: StreamPlayer
    private lateinit var playerView: PlayerView
    private lateinit var rules: RuleEngine

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        rules = ContentRuleEngine.from(
            assets.open("blocklist.json").bufferedReader().use { it.readText() },
        )

        streamPlayer = StreamPlayer(this)
        playerView = PlayerView(this).apply {
            player = streamPlayer.exo
            visibility = android.view.View.GONE
        }

        web = CliqxWebView(this, rules, ::handle)

        setContentView(
            FrameLayout(this).apply {
                addView(web)
                addView(playerView)
            },
        )

        web.loadUrl(START_URL)
    }

    /**
     * Where the skeleton stops. On iOS each of these drives player chrome,
     * theater state and episode navigation; here they are logged so a run can
     * be checked against the iOS behaviour, and only the two that prove the
     * architecture do anything.
     */
    private fun handle(message: BridgeMessage, frameId: String?) {
        Log.i(TAG, "bridge: $message (frame=$frameId)")

        when (message) {
            is BridgeMessage.Ready ->
                Log.i(TAG, "Agent is live in frame $frameId — injection works.")

            is BridgeMessage.WatchCleanTapped -> resolveAndPlay()

            is BridgeMessage.PopupBlocked ->
                Log.i(TAG, "popupguard stopped a popup; blocked=${rules.blockedCount}")

            else -> Unit
        }
    }

    /**
     * Asks the agent for a stream it can hand over, then gives it to ExoPlayer.
     *
     * `streamCandidates` is the agent's existing surface, unchanged — the same
     * call the iOS app makes.
     */
    private fun resolveAndPlay() {
        web.callAgent("streamCandidates()") { result ->
            Log.i(TAG, "streamCandidates -> $result")
            val url = firstUrl(result)
            if (url == null) {
                Log.w(TAG, "No handoff candidate; staying in the page.")
                return@callAgent
            }
            runOnUiThread {
                playerView.visibility = android.view.View.VISIBLE
                streamPlayer.play(url)
            }
        }
    }

    /** Minimal extraction; the real path decodes the agent's candidate list. */
    private fun firstUrl(json: String): String? =
        Regex("https?://[^\"\\\\]+").find(json)?.value

    override fun onDestroy() {
        streamPlayer.release()
        web.destroy()
        super.onDestroy()
    }

    private companion object {
        const val TAG = "Cliqx"
        const val START_URL = "https://example.com"
    }
}
