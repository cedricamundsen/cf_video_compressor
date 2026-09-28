package com.combatflux.cf_video_compressor

import android.content.Context
import android.media.MediaCodecInfo
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.File

/** Settings for exactly one encode attempt (decided by the Dart planner). */
internal data class CompressArgs(
    val attempt: Int,
    val videoBitrate: Int,
    /** 0 = source has no audio track. */
    val audioBitrate: Int,
    /** Output short side in px, or null to keep the source size. */
    val targetShortSide: Int?,
    /** Frame-rate cap, or null to keep the source frame rate. */
    val maxFrameRate: Float?,
    val toneMapHdrToSdr: Boolean,
    val cbr: Boolean,
)

/**
 * One Media3 Transformer export: source URI -> H.264/AAC MP4 at [output].
 *
 * Threading: created, started, polled and cancelled on the main looper
 * (Transformer must be used from a single application thread). Decoding,
 * GL processing, encoding and muxing run on Media3's internal threads and
 * stream through MediaCodec buffers; the file is never held in memory.
 */
@OptIn(UnstableApi::class)
internal class CompressionJob(
    private val context: Context,
    private val source: Uri,
    val output: File,
    val args: CompressArgs,
    private val onProgress: (attempt: Int, percent: Int, state: String) -> Unit,
    private val onDone: (result: ExportResult?, error: ExportException?, elapsedMs: Long, cancelled: Boolean) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val holder = ProgressHolder()
    private var transformer: Transformer? = null
    private var startedAt = 0L
    private var finished = false

    /** Real progress from the export pipeline, sampled every 500 ms. */
    private val poll = object : Runnable {
        override fun run() {
            val t = transformer ?: return
            if (finished) return
            when (t.getProgress(holder)) {
                Transformer.PROGRESS_STATE_AVAILABLE ->
                    onProgress(args.attempt, holder.progress, "running")
                Transformer.PROGRESS_STATE_WAITING_FOR_AVAILABILITY ->
                    onProgress(args.attempt, -1, "waiting")
                Transformer.PROGRESS_STATE_UNAVAILABLE ->
                    onProgress(args.attempt, -1, "unavailable")
                else -> Unit
            }
            main.postDelayed(this, POLL_INTERVAL_MS)
        }
    }

    fun start() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "start() must run on the main thread" }

        // Video effects, applied in display orientation (after rotation):
        // 1) drop frames down to ~30 fps (timestamps kept -> same speed),
        // 2) scale so the short side is 720/540, long side keeps aspect.
        val videoEffects = ArrayList<Effect>()
        args.maxFrameRate?.let { videoEffects.add(FrameDropEffect.createDefaultFrameDropEffect(it)) }
        args.targetShortSide?.let { videoEffects.add(Presentation.createForShortSide(it)) }

        // No clipping, no speed change, no audio processors: full duration,
        // original timestamps, original audio (re-encoded to AAC).
        val item = EditedMediaItem.Builder(MediaItem.fromUri(source))
            .setEffects(Effects(emptyList(), videoEffects))
            .build()
        val sequence = if (args.audioBitrate > 0) {
            EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item))
        } else {
            EditedMediaItemSequence.withVideoFrom(listOf(item))
        }
        val composition = Composition.Builder(sequence)
            .setHdrMode(
                if (args.toneMapHdrToSdr) Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
                else Composition.HDR_MODE_KEEP_HDR,
            )
            .build()

        // Non-default encoder settings force a real transcode (no transmux).
        val video = VideoEncoderSettings.Builder()
            .setBitrate(args.videoBitrate)
            .setBitrateMode(
                if (args.cbr) MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
                else MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR,
            )
            .build()
        val encoders = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(video)
            .setEnableFallback(true) // let Media3 pick the closest supported config
        if (args.audioBitrate > 0) {
            encoders.setRequestedAudioEncoderSettings(
                AudioEncoderSettings.Builder().setBitrate(args.audioBitrate).build(),
            )
        }

        val t = Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoders.build())
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    finish(exportResult, null)
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    finish(exportResult, exportException)
                }
            })
            .build()
        transformer = t
        startedAt = SystemClock.elapsedRealtime()
        t.start(composition, output.absolutePath)
        onProgress(args.attempt, 0, "running")
        main.postDelayed(poll, POLL_INTERVAL_MS)
    }

    /** Stops the export and deletes the partial output. Main thread. */
    fun cancel(): Boolean {
        if (finished) return false
        finished = true
        main.removeCallbacks(poll)
        try { transformer?.cancel() } catch (_: Exception) {}
        output.delete()
        onDone(null, null, SystemClock.elapsedRealtime() - startedAt, true)
        return true
    }

    private fun finish(result: ExportResult, error: ExportException?) {
        if (finished) return
        finished = true
        main.removeCallbacks(poll)
        if (error != null) {
            output.delete() // never leave a broken file behind
        } else {
            onProgress(args.attempt, 100, "running")
        }
        onDone(result, error, SystemClock.elapsedRealtime() - startedAt, false)
    }

    companion object {
        private const val POLL_INTERVAL_MS = 500L

        fun conversionName(process: Int): String = when (process) {
            ExportResult.CONVERSION_PROCESS_TRANSCODED -> "transcoded"
            ExportResult.CONVERSION_PROCESS_TRANSMUXED -> "transmuxed"
            ExportResult.CONVERSION_PROCESS_TRANSMUXED_AND_TRANSCODED -> "transmuxed+transcoded"
            else -> "n/a"
        }
    }
}
