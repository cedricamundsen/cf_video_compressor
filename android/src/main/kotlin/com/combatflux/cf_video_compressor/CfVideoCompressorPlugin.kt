package com.combatflux.cf_video_compressor

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Android side of CfVideoCompressorPlatform.
 *
 * Methods (channel com.combatflux/cf_video_compressor):
 *   pickVideo, getVideoInfo, compress, cancel, deleteOutput,
 *   deleteAllOutputs, tempDirectory, saveCopyToMovies
 * Events (com.combatflux/cf_video_compressor/progress):
 *   {attempt, percent (0-100 or -1), state}
 *
 * Only strings and numbers cross the channel; video bytes never do.
 */
@OptIn(UnstableApi::class)
class CfVideoCompressorPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    EventChannel.StreamHandler {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPick: MethodChannel.Result? = null
    private var job: CompressionJob? = null
    private val main = Handler(Looper.getMainLooper())
    private var io: ExecutorService? = null

    // --- FlutterPlugin -------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "com.combatflux/cf_video_compressor")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "com.combatflux/cf_video_compressor/progress")
        events.setStreamHandler(this)
        io = Executors.newSingleThreadExecutor()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        job?.cancel()
        job = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        io?.shutdown()
        io = null
    }

    // --- EventChannel ---------------------------------------------------------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // --- Methods ------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickVideo" -> pickVideo(result)
            "getVideoInfo" -> {
                val uri = call.argument<String>("uri")
                    ?: return result.error("BAD_ARGS", "uri is required", null)
                background(result, "SOURCE_UNREADABLE") {
                    VideoProbe.probe(context, VideoProbe.parseUri(uri))
                }
            }
            "compress" -> compress(call, result)
            "cancel" -> result.success(job?.cancel() ?: false)
            "deleteOutput" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("BAD_ARGS", "path is required", null)
                if (job?.output?.absolutePath == path) {
                    return result.error("BUSY", "That output is still being written", null)
                }
                background(result, "DELETE_FAILED") { OutputStore.delete(context, path) }
            }
            "deleteAllOutputs" -> {
                if (job != null) return result.error("BUSY", "A compression is running", null)
                background(result, "DELETE_FAILED") { OutputStore.deleteAll(context) }
            }
            "tempDirectory" -> result.success(OutputStore.dir(context).absolutePath)
            "availableTempBytes" -> background(result, "IO_FAILED") { OutputStore.availableBytes(context) }
            "copySourceToTemp" -> {
                val uri = call.argument<String>("uri")
                    ?: return result.error("BAD_ARGS", "uri is required", null)
                val expected = call.argument<Number>("expectedBytes")?.toLong() ?: -1L
                val executor = io ?: return result.error("DETACHED", "Plugin detached", null)
                executor.execute {
                    try {
                        val f = OutputStore.copySourceToTemp(context, VideoProbe.parseUri(uri), expected)
                        main.post { result.success(mapOf("path" to f.absolutePath, "sizeBytes" to f.length())) }
                    } catch (e: OutputStore.NoSpaceException) {
                        main.post { result.error("NO_SPACE", e.message, null) }
                    } catch (e: Exception) {
                        main.post { result.error("SOURCE_UNREADABLE", e.message ?: e.javaClass.simpleName, null) }
                    }
                }
            }
            "saveCopyToMovies" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("BAD_ARGS", "path is required", null)
                background(result, "SAVE_FAILED") { OutputStore.saveCopyToMovies(context, path) }
            }
            else -> result.notImplemented()
        }
    }

    /** Runs blocking I/O off the main thread; replies on the main thread. */
    private fun background(result: MethodChannel.Result, errorCode: String, block: () -> Any?) {
        val executor = io ?: return result.error("DETACHED", "Plugin detached", null)
        executor.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error(errorCode, e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    // --- Picker ---------------------------------------------------------------

    /**
     * System document picker (Storage Access Framework). Returns a
     * content:// URI with a read grant; nothing is copied or read here.
     */
    private fun pickVideo(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
            ?: return result.error("NO_ACTIVITY", "No foreground activity", null)
        if (pendingPick != null) return result.error("BUSY", "Picker already open", null)
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "video/*"
        }
        pendingPick = result
        try {
            activity.startActivityForResult(intent, PICK_REQUEST_CODE)
        } catch (e: Exception) {
            pendingPick = null
            result.error("PICKER_UNAVAILABLE", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST_CODE) return false
        val r = pendingPick ?: return true
        pendingPick = null
        val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null
        r.success(uri?.toString())
        return true
    }

    // --- Compression ------------------------------------------------------------

    private fun compress(call: MethodCall, result: MethodChannel.Result) {
        if (job != null) return result.error("BUSY", "A compression is already running", null)
        val uri = call.argument<String>("uri")
            ?: return result.error("BAD_ARGS", "uri is required", null)
        val videoBitrate = call.argument<Number>("videoBitrate")?.toInt()
            ?: return result.error("BAD_ARGS", "videoBitrate is required", null)
        if (videoBitrate <= 0) return result.error("BAD_ARGS", "videoBitrate must be > 0", null)

        val args = CompressArgs(
            attempt = call.argument<Number>("attempt")?.toInt() ?: 1,
            videoBitrate = videoBitrate,
            audioBitrate = call.argument<Number>("audioBitrate")?.toInt() ?: 64000,
            targetShortSide = call.argument<Number>("targetShortSide")?.toInt(),
            maxFrameRate = call.argument<Number>("maxFrameRate")?.toFloat(),
            toneMapHdrToSdr = call.argument<Boolean>("toneMapHdrToSdr") ?: true,
            cbr = call.argument<String>("bitrateMode") == "cbr",
        )
        // Fail fast (before touching the encoder) when the output cannot fit.
        val required = call.argument<Number>("requiredBytes")?.toLong() ?: 0L
        if (required > 0 && OutputStore.availableBytes(context) < required) {
            return result.error(
                "NO_SPACE",
                "Need $required bytes free, have ${OutputStore.availableBytes(context)}",
                null,
            )
        }
        val output = OutputStore.newOutputFile(context, args.attempt)

        val newJob = CompressionJob(
            context = context,
            source = VideoProbe.parseUri(uri),
            output = output,
            args = args,
            onProgress = { attempt, percent, state ->
                eventSink?.success(mapOf("attempt" to attempt, "percent" to percent, "state" to state))
            },
            onDone = { export, error, elapsedMs, cancelled ->
                job = null
                when {
                    cancelled -> result.error("CANCELLED", "Cancelled; partial output deleted", null)
                    error != null -> result.error(
                        classify(error),
                        "${error.errorCodeName}: ${error.message}",
                        mapOf("errorCode" to error.errorCode, "elapsedMs" to elapsedMs),
                    )
                    else -> background(result, "OUTPUT_UNREADABLE") {
                        describeOutput(output, export!!, args, elapsedMs)
                    }
                }
            },
        )
        job = newJob
        try {
            newJob.start()
        } catch (e: Exception) {
            job = null
            output.delete()
            result.error("EXPORT_FAILED", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /** Maps a Media3 failure to the categories the app shows messages for. */
    private fun classify(e: ExportException): String {
        if (OutputStore.isNoSpace(e)) return "NO_SPACE"
        return when (e.errorCode) {
            ExportException.ERROR_CODE_DECODER_INIT_FAILED,
            ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
            ExportException.ERROR_CODE_DECODING_FAILED -> "UNSUPPORTED_INPUT"
            ExportException.ERROR_CODE_IO_FILE_NOT_FOUND,
            ExportException.ERROR_CODE_IO_NO_PERMISSION,
            ExportException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE -> "SOURCE_UNREADABLE"
            else -> "EXPORT_FAILED"
        }
    }

    /** Re-probes the finished file so the report shows what is really on disk. */
    private fun describeOutput(
        output: File,
        export: ExportResult,
        args: CompressArgs,
        elapsedMs: Long,
    ): Map<String, Any?> {
        val probed = VideoProbe.probe(context, Uri.fromFile(output))
        return mapOf(
            "attempt" to args.attempt,
            "outputPath" to output.absolutePath,
            "outputSizeBytes" to output.length(),
            "outputWidth" to probed["width"],
            "outputHeight" to probed["height"],
            "outputRotationDegrees" to probed["rotationDegrees"],
            "outputDurationMs" to ((probed["durationMs"] as? Long)?.takeIf { it > 0 }
                ?: export.approximateDurationMs),
            "outputFrameRate" to probed["frameRate"],
            "outputVideoMime" to probed["videoMime"],
            "outputAudioMime" to probed["audioMime"],
            "averageVideoBitrate" to export.averageVideoBitrate,
            "averageAudioBitrate" to export.averageAudioBitrate,
            "videoEncoderName" to export.videoEncoderName,
            "audioEncoderName" to export.audioEncoderName,
            "videoConversion" to CompressionJob.conversionName(export.videoConversionProcess),
            "audioConversion" to CompressionJob.conversionName(export.audioConversionProcess),
            "elapsedMs" to elapsedMs,
        )
    }

    // --- ActivityAware ------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    private companion object {
        const val PICK_REQUEST_CODE = 0xCF01
    }
}
