package com.saisamardh.cliqx.browser

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.saisamardh.cliqx.blocking.RuleEngine
import com.saisamardh.cliqx.bridge.AgentBridge
import com.saisamardh.cliqx.bridge.BridgeMessage
import java.io.ByteArrayInputStream

/**
 * The browser surface: a WebView that injects the shared agent and refuses
 * requests the rule engine rejects.
 *
 * Mirrors `ios/Sources/CleanPlayer/BrowserSetup.swift` in intent. The two
 * mechanisms with no Android equivalent are called out at their call sites.
 */
@SuppressLint("SetJavaScriptEnabled")
class CliqxWebView(
    context: Context,
    private val ruleEngine: RuleEngine,
    private val onMessage: (BridgeMessage, String?) -> Unit,
) : WebView(context) {

    /** Host of the page currently loaded, for third-party determination. */
    @Volatile
    private var documentHost: String? = null

    init {
        settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            // The agent cancels new-window attempts at the policy layer on
            // iOS. Here popupguard.js stubs window.open in the page world, and
            // this stops the WebView honouring any that slip past.
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
        }

        addJavascriptInterface(
            AgentBridge(onMessage),
            AgentBridge.JS_INTERFACE_NAME,
        )

        installDocumentStartScripts(context)
        webViewClient = BlockingClient()
    }

    /**
     * Injects the shim, popupguard and the agent before any page script runs.
     *
     * `addDocumentStartJavaScript` is the only Android API that matches
     * WKUserScript's `atDocumentStart` in every frame; it needs WebView 83+,
     * which is why the feature is checked rather than assumed. Order matters:
     * the shim must define `window.webkit.messageHandlers.cp` before the agent
     * reads it, and popupguard must replace `window.open` before the page can
     * call it.
     *
     * Without the feature there is no correct fallback —
     * `onPageStarted` + `evaluateJavascript` races the page's own scripts and
     * loses often enough that popupguard would miss the popups it exists to
     * stop. So the app degrades loudly instead of silently.
     */
    private fun installDocumentStartScripts(context: Context) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            Log.e(
                TAG,
                "WebView is too old for document-start injection; " +
                    "the agent and popup guard will not run.",
            )
            return
        }

        // "*" because the agent runs in every frame, including cross-origin ad
        // frames — those are precisely the ones popupguard needs to reach.
        val allOrigins = setOf("*")
        for (asset in DOCUMENT_START_ASSETS) {
            val source = try {
                read(context, asset)
            } catch (error: Exception) {
                Log.e(TAG, "Missing asset $asset: ${error.message}")
                continue
            }
            WebViewCompat.addDocumentStartJavaScript(this, source, allOrigins)
        }

        // The agent goes in last and wrapped; see agent-bootstrap.js for why it
        // cannot run at true document start on this engine.
        val wrapped = try {
            val bootstrap = read(context, AGENT_BOOTSTRAP_ASSET)
            // Checked before substituting, not after: afterwards the
            // placeholder is absent whether it was replaced or was never
            // there, so the obvious assertion would always pass.
            if (!bootstrap.contains(AGENT_PLACEHOLDER)) {
                Log.e(
                    TAG,
                    "agent-bootstrap.js has no $AGENT_PLACEHOLDER marker, " +
                        "so the agent would never start. Injecting nothing.",
                )
                return
            }
            bootstrap.replace(AGENT_PLACEHOLDER, read(context, AGENT_ASSET))
        } catch (error: Exception) {
            Log.e(TAG, "Could not assemble the agent: ${error.message}")
            return
        }
        WebViewCompat.addDocumentStartJavaScript(this, wrapped, allOrigins)
    }

    private fun read(context: Context, asset: String): String =
        context.assets.open(asset).bufferedReader().use { it.readText() }

    private inner class BlockingClient : WebViewClient() {

        override fun onPageStarted(
            view: WebView?,
            url: String?,
            favicon: android.graphics.Bitmap?,
        ) {
            documentHost = url?.let { android.net.Uri.parse(it).host }
            super.onPageStarted(view, url, favicon)
        }

        /**
         * Called on a background thread for every subresource. The return value
         * is the block: an empty response, not null, because null means "load
         * it normally".
         *
         * A blocked request must not look like a network failure to the page —
         * some players retry those forever. An empty 200 reads as a resource
         * that simply had nothing in it.
         */
        override fun shouldInterceptRequest(
            view: WebView?,
            request: WebResourceRequest?,
        ): WebResourceResponse? {
            val url = request?.url?.toString() ?: return null
            if (!ruleEngine.shouldBlock(url, documentHost)) return null

            return WebResourceResponse(
                "text/plain",
                "utf-8",
                ByteArrayInputStream(ByteArray(0)),
            )
        }
    }

    /** Calls into the agent's `window.__cp` surface. */
    fun callAgent(expression: String, onResult: (String) -> Unit = {}) {
        evaluateJavascript("window.__cp && window.__cp.$expression", onResult)
    }

    private companion object {
        const val TAG = "CliqxWebView"

        /**
         * Injection order is load-bearing: the shim must define
         * `window.webkit.messageHandlers.cp` before the agent reads it, and
         * popupguard must replace `window.open` before the page can call it.
         * Neither needs a DOM, so both run at true document start.
         */
        val DOCUMENT_START_ASSETS = listOf(
            "bridge-shim.js",
            "popupguard.js",
        )

        const val AGENT_ASSET = "agent.js"
        const val AGENT_BOOTSTRAP_ASSET = "agent-bootstrap.js"

        /** Replaced with the agent's source; must match agent-bootstrap.js. */
        const val AGENT_PLACEHOLDER = "/*{{AGENT}}*/"
    }
}
