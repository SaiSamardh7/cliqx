package com.saisamardh.cliqx.bridge

import android.util.Log
import android.webkit.JavascriptInterface

/**
 * The Android end of the page agent's channel.
 *
 * Every method here is reachable by any JavaScript in any frame the WebView
 * loads, including a hostile ad frame — `addJavascriptInterface` has no origin
 * restriction and no content worlds exist to hide behind. So this class
 * deliberately exposes exactly one entry point that only accepts a string, and
 * forwards nothing a caller cannot already do: decoding runs through
 * [BridgeMessage.decode], and a payload that fails validation is dropped.
 */
class AgentBridge(
    private val onMessage: (BridgeMessage, String?) -> Unit,
) {
    @JavascriptInterface
    fun post(payload: String) {
        // A page could call this directly with megabytes. Reject before parsing.
        if (payload.length > MAX_PAYLOAD_LENGTH) return

        val decoded = try {
            BridgeMessage.decode(payload)
        } catch (error: BridgeMessage.ValidationError) {
            Log.d(TAG, "Rejected bridge payload: ${error.message}")
            return
        } catch (error: Exception) {
            Log.d(TAG, "Malformed bridge payload: ${error.message}")
            return
        }

        onMessage(decoded.first, decoded.second)
    }

    companion object {
        private const val TAG = "CliqxBridge"

        /** The global the shim looks for. Must match `bridge-shim.js`. */
        const val JS_INTERFACE_NAME = "__cliqxNative"

        /** Generous for a real agent message, far below a denial-of-service. */
        private const val MAX_PAYLOAD_LENGTH = 1 shl 20
    }
}
