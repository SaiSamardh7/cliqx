package com.saisamardh.cliqx.bridge

import org.json.JSONObject

/**
 * Versioned messages accepted from the page agent.
 *
 * A port of `ios/Sources/CleanPlayer/BridgeMessage.swift`, holding the same
 * line: the page is untrusted input, so decoding rejects missing fields,
 * unknown kinds, non-finite numbers and out-of-range values before the app
 * mutates any state. The limits below are the Swift ones, deliberately —
 * the two platforms consume the same agent and must agree on what it may say.
 */
sealed interface BridgeMessage {

    /** Why a staged video will not play. A closed set: the message the user */
    /** sees is written here and never taken from the page. */
    enum class MediaErrorReason(val wire: String) {
        DRM("drm"),
        UNSUPPORTED("unsupported"),
        NETWORK("network");

        val message: String
            get() = when (this) {
                DRM ->
                    "This video is protected by DRM, which Cliqx can't play. " +
                        "Try the site's own app, or Chrome."
                UNSUPPORTED -> "This video is in a format Cliqx can't play."
                NETWORK -> "The video stopped downloading. Check your connection."
            }

        companion object {
            fun from(raw: String): MediaErrorReason? = entries.find { it.wire == raw }
        }
    }

    data class MediaChoice(val index: Int, val label: String, val active: Boolean)

    data class VideoInfo(
        val height: Int,
        val width: Int,
        val fit: String,
        val sources: List<MediaChoice>,
    )

    data object Ready : BridgeMessage
    data object FrameGone : BridgeMessage
    data class Theater(val airplay: Boolean, val pip: Boolean) : BridgeMessage
    data object TheaterEnded : BridgeMessage
    data object TheaterFailed : BridgeMessage
    data class MediaError(val reason: MediaErrorReason) : BridgeMessage
    data object Ended : BridgeMessage
    data object WatchCleanTapped : BridgeMessage
    data class Blocked(val count: Int) : BridgeMessage
    data object PopupBlocked : BridgeMessage
    data class Playback(
        val playing: Boolean,
        val buffering: Boolean,
        val armed: Boolean,
    ) : BridgeMessage
    data class EpisodeSourceChanged(val playing: Boolean) : BridgeMessage
    data class Volume(
        val percent: Int,
        val boosted: Boolean,
        val available: Boolean,
    ) : BridgeMessage
    data class Time(
        val at: Double,
        val duration: Double,
        val live: Boolean,
        val buffered: Double,
        val rate: Double,
    ) : BridgeMessage
    data class Video(val info: VideoInfo) : BridgeMessage
    data class Tracks(val choices: List<MediaChoice>) : BridgeMessage

    sealed class ValidationError(message: String) : Exception(message) {
        data object MalformedPayload :
            ValidationError("The payload is not a JSON object.")
        data class UnsupportedVersion(val version: Int) :
            ValidationError("Unsupported bridge protocol version: $version.")
        data class UnknownType(val type: String) :
            ValidationError("Unknown bridge message type: $type.")
        data class StringTooLong(val field: String) :
            ValidationError("Bridge field $field exceeds $MAX_STRING_LENGTH characters.")
        data class NumberOutOfRange(val field: String) :
            ValidationError("Bridge field $field is outside its accepted range.")
        data class TooManyItems(val field: String) :
            ValidationError("Bridge field $field contains too many items.")
    }

    companion object {
        const val PROTOCOL_VERSION = 1
        const val MAX_STRING_LENGTH = 2_048
        private const val MAX_COLLECTION_COUNT = 1_000
        private const val MAX_MEDIA_INDEX = 100_000
        private const val MAX_MEDIA_DIMENSION = 32_768
        private const val MAX_MEDIA_TIME = 31_536_000.0

        /**
         * Decodes one message, or throws [ValidationError].
         *
         * The frame id travels alongside every payload as `fid`; it is returned
         * separately rather than folded into the message because routing is the
         * host's concern, not the message's.
         */
        fun decode(raw: String): Pair<BridgeMessage, String?> {
            val json = try {
                JSONObject(raw)
            } catch (_: Exception) {
                throw ValidationError.MalformedPayload
            }

            val version = if (json.has("v")) json.optInt("v", -1) else -1
            if (version != PROTOCOL_VERSION) {
                throw ValidationError.UnsupportedVersion(version)
            }

            val frameId = json.optString("fid").takeIf { it.isNotEmpty() }
            val type = json.optString("type").takeIf { it.isNotEmpty() }
                ?: throw ValidationError.MalformedPayload

            return decodeBody(type, json) to frameId
        }

        private fun decodeBody(type: String, json: JSONObject): BridgeMessage =
            when (type) {
                "ready" -> Ready
                "frameGone" -> FrameGone
                "theaterEnded" -> TheaterEnded
                "theaterFailed" -> TheaterFailed
                "ended" -> Ended
                "watchCleanTapped" -> WatchCleanTapped
                "popupBlocked" -> PopupBlocked

                "theater" -> Theater(
                    airplay = json.optBoolean("airplay"),
                    pip = json.optBoolean("pip"),
                )

                "mediaError" -> MediaError(
                    reason = MediaErrorReason.from(json.optString("reason"))
                        ?: throw ValidationError.UnknownType("mediaError.reason"),
                )

                "blocked" -> Blocked(
                    count = json.requireInt("count", 0, MAX_COLLECTION_COUNT * 1_000),
                )

                "playback" -> Playback(
                    playing = json.optBoolean("playing"),
                    buffering = json.optBoolean("buffering"),
                    armed = json.optBoolean("armed"),
                )

                "episodeSourceChanged" -> EpisodeSourceChanged(
                    playing = json.optBoolean("playing"),
                )

                "volume" -> Volume(
                    percent = json.requireInt("percent", 0, 1_000),
                    boosted = json.optBoolean("boosted"),
                    available = json.optBoolean("available"),
                )

                "time" -> Time(
                    at = json.requireFinite("at", 0.0, MAX_MEDIA_TIME),
                    duration = json.requireFinite("duration", 0.0, MAX_MEDIA_TIME),
                    live = json.optBoolean("live"),
                    buffered = json.requireFinite("buffered", 0.0, MAX_MEDIA_TIME),
                    rate = json.requireFinite("rate", 0.0, 16.0),
                )

                "video" -> Video(
                    info = VideoInfo(
                        height = json.requireInt("height", 0, MAX_MEDIA_DIMENSION),
                        width = json.requireInt("width", 0, MAX_MEDIA_DIMENSION),
                        fit = json.requireBoundedString("fit"),
                        sources = json.decodeChoices("sources"),
                    ),
                )

                "tracks" -> Tracks(choices = json.decodeChoices("tracks"))

                else -> throw ValidationError.UnknownType(type)
            }

        private fun JSONObject.requireBoundedString(field: String): String {
            val value = optString(field)
            if (value.length > MAX_STRING_LENGTH) {
                throw ValidationError.StringTooLong(field)
            }
            return value
        }

        private fun JSONObject.requireInt(field: String, min: Int, max: Int): Int {
            if (!has(field)) throw ValidationError.MalformedPayload
            val value = optDouble(field, Double.NaN)
            if (!value.isFinite() || value < min || value > max) {
                throw ValidationError.NumberOutOfRange(field)
            }
            return value.toInt()
        }

        private fun JSONObject.requireFinite(
            field: String,
            min: Double,
            max: Double,
        ): Double {
            if (!has(field)) throw ValidationError.MalformedPayload
            val value = optDouble(field, Double.NaN)
            if (!value.isFinite() || value < min || value > max) {
                throw ValidationError.NumberOutOfRange(field)
            }
            return value
        }

        private fun JSONObject.decodeChoices(field: String): List<MediaChoice> {
            val array = optJSONArray(field) ?: return emptyList()
            if (array.length() > MAX_COLLECTION_COUNT) {
                throw ValidationError.TooManyItems(field)
            }
            return (0 until array.length()).map { position ->
                val item = array.optJSONObject(position)
                    ?: throw ValidationError.MalformedPayload
                MediaChoice(
                    index = item.requireInt("index", 0, MAX_MEDIA_INDEX),
                    label = item.requireBoundedString("label"),
                    active = item.optBoolean("active"),
                )
            }
        }
    }
}
