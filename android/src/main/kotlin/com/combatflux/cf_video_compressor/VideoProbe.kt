package com.combatflux.cf_video_compressor

import android.content.ContentResolver
import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.File

/**
 * Reads container/track metadata without decoding frames and without
 * loading the file: ContentResolver for size/name, MediaMetadataRetriever
 * for duration/dimensions/rotation, MediaExtractor for codecs/frame rate.
 * Must be called off the main thread (providers may do I/O).
 */
internal object VideoProbe {

    /** Accepts content://, file:// or an absolute path. */
    fun parseUri(value: String): Uri =
        if (value.startsWith("/")) Uri.fromFile(File(value)) else Uri.parse(value)

    fun probe(context: Context, uri: Uri): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        out["uri"] = uri.toString()

        // --- size + display name -------------------------------------------
        var size = -1L
        var name: String? = null
        if (uri.scheme == ContentResolver.SCHEME_CONTENT) {
            context.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }
            }
            if (size < 0) {
                context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { size = it.length }
            }
        } else {
            val f = File(requireNotNull(uri.path) { "Unsupported URI: $uri" })
            if (!f.exists()) throw IllegalArgumentException("File not found: ${f.path}")
            size = f.length()
            name = f.name
        }
        out["sizeBytes"] = size
        out["displayName"] = name

        // --- duration / dimensions / rotation -------------------------------
        var durationMs = 0L
        var frameCount: Int? = null
        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(context, uri)
            fun key(k: Int): String? = mmr.extractMetadata(k)
            durationMs = key(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            out["durationMs"] = durationMs
            out["width"] = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            out["height"] = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            out["rotationDegrees"] =
                key(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            out["bitrate"] = key(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull()
            if (Build.VERSION.SDK_INT >= 28) {
                frameCount =
                    key(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toIntOrNull()
            }
        } finally {
            try { mmr.release() } catch (_: Exception) {}
        }

        // --- tracks: codecs, frame rate, audio ------------------------------
        var frameRate: Double? = null
        var hasAudio = false
        val ex = MediaExtractor()
        try {
            ex.setDataSource(context, uri, null)
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && out["videoMime"] == null) {
                    out["videoMime"] = mime
                    frameRate = f.number(MediaFormat.KEY_FRAME_RATE)
                    out["videoBitrate"] = f.number(MediaFormat.KEY_BIT_RATE)?.toInt()
                    out["colorTransfer"] = f.number(MediaFormat.KEY_COLOR_TRANSFER)?.toInt()
                } else if (mime.startsWith("audio/") && !hasAudio) {
                    hasAudio = true
                    out["audioMime"] = mime
                    out["audioBitrate"] = f.number(MediaFormat.KEY_BIT_RATE)?.toInt()
                    out["audioChannels"] = f.number(MediaFormat.KEY_CHANNEL_COUNT)?.toInt()
                    out["audioSampleRate"] = f.number(MediaFormat.KEY_SAMPLE_RATE)?.toInt()
                }
            }
        } finally {
            ex.release()
        }
        // Fallback: average fps from frame count (API 28+).
        if ((frameRate == null || frameRate <= 0.0) && frameCount != null && durationMs > 0) {
            frameRate = frameCount * 1000.0 / durationMs
        }
        out["frameRate"] = frameRate
        out["hasAudio"] = hasAudio
        return out
    }

    /** Integer or float MediaFormat entry as Double (vendors use both). */
    private fun MediaFormat.number(key: String): Double? {
        if (!containsKey(key)) return null
        return try {
            getInteger(key).toDouble()
        } catch (_: Exception) {
            try { getFloat(key).toDouble() } catch (_: Exception) {
                try { getLong(key).toDouble() } catch (_: Exception) { null }
            }
        }
    }
}
