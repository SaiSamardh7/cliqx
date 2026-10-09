package com.saisamardh.cliqx.player

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory

/**
 * The native player the browser hands a stream to.
 *
 * This is the Android answer to Mode B, and the one place the README's
 * "iOS only, architectural" claim is right about the mechanism:
 * `webkitEnterFullscreen` has no counterpart here. What replaces it is not a
 * shim but a different design — rather than asking the page's own `<video>` to
 * go full screen, the resolved stream URL is handed to ExoPlayer and the page
 * keeps playing nothing. That needs no cooperation from the page at all.
 *
 * What it loses is every source that cannot be reduced to a URL ExoPlayer can
 * open on its own: DRM, and the blob/MSE sources the agent can see but not
 * hand over. On iOS those still play, because the page's own video element is
 * what goes full screen. This is the real functional gap between the two
 * platforms, and it is not closable by porting more code.
 */
// Media3 marks DefaultHttpDataSource, DefaultMediaSourceFactory and
// setMediaSourceFactory @UnstableApi, which is RequiresOptIn at ERROR level —
// so this does not compile without the opt-in. Declared on the class rather
// than per member to keep the surface in one visible place.
@OptIn(UnstableApi::class)
class StreamPlayer(context: Context) {

    /**
     * Headers have to be set on the data source, not the [MediaItem] —
     * `RequestMetadata` extras are carried for the app's own use and are never
     * sent on the wire. Many video CDNs 403 without a `Referer` matching the
     * embedding page, so this is load-bearing rather than defensive.
     *
     * Mutable because the referer is per-stream and the factory is built once.
     */
    private val headers = mutableMapOf<String, String>()

    private val httpFactory = DefaultHttpDataSource.Factory()
        .setAllowCrossProtocolRedirects(true)
        .setDefaultRequestProperties(headers)

    val exo: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(DefaultMediaSourceFactory(httpFactory))
        .build()

    /**
     * HLS and DASH are both on the classpath via `build.gradle.kts`, and
     * ExoPlayer infers the source type from the manifest — which is what the
     * agent's `isManifestURL` is already detecting on the page side.
     */
    fun play(url: String, requestHeaders: Map<String, String> = emptyMap()) {
        // Mutating the same map the factory holds, so this must happen before
        // prepare() opens the first connection.
        headers.clear()
        headers += requestHeaders
        httpFactory.setDefaultRequestProperties(headers)

        exo.setMediaItem(MediaItem.fromUri(url))
        exo.prepare()
        exo.playWhenReady = true
    }

    fun stop() {
        exo.stop()
        exo.clearMediaItems()
    }

    fun release() = exo.release()

    val isPlaying: Boolean get() = exo.isPlaying

    fun addListener(listener: Player.Listener) = exo.addListener(listener)
}
