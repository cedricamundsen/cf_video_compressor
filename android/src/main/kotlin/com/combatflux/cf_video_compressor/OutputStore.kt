package com.combatflux.cf_video_compressor

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream
import java.io.IOException

/**
 * Owns the temp directory for compressed outputs:
 *   <externalCacheDir or cacheDir>/cf_compress/cf_<epochMs>_a<attempt>.mp4
 * App-private, never the source's location, deletable by name/pattern.
 * The OS may also purge the cache dir under storage pressure.
 */
internal object OutputStore {
    private const val DIR_NAME = "cf_compress"

    fun dir(context: Context): File {
        val base = context.externalCacheDir ?: context.cacheDir
        return File(base, DIR_NAME).apply { mkdirs() }
    }

    fun newOutputFile(context: Context, attempt: Int): File =
        File(dir(context), "cf_${System.currentTimeMillis()}_a$attempt.mp4")

    /** Free bytes on the volume that holds [dir]. */
    fun availableBytes(context: Context): Long = dir(context).usableSpace

    /** True only for our own cf_* files directly inside [dir]. */
    fun isOwned(context: Context, file: File): Boolean {
        val parent = file.canonicalFile.parentFile ?: return false
        return parent == dir(context).canonicalFile && file.name.startsWith("cf_")
    }

    /**
     * Streams the (already small enough) source into the temp dir so Dart can
     * read it as a plain file. 1 MiB buffer; the source is only read.
     * Throws [NoSpaceException] when the copy would not fit.
     */
    fun copySourceToTemp(context: Context, source: android.net.Uri, expectedBytes: Long): File {
        val margin = 16L * 1024 * 1024
        if (expectedBytes > 0 && availableBytes(context) < expectedBytes + margin) {
            throw NoSpaceException("Need ${expectedBytes + margin} bytes, have ${availableBytes(context)}")
        }
        val out = File(dir(context), "cf_${System.currentTimeMillis()}_src.mp4")
        try {
            val input = if (source.scheme == "file") {
                FileInputStream(File(requireNotNull(source.path)))
            } else {
                context.contentResolver.openInputStream(source)
                    ?: throw IOException("Cannot open $source")
            }
            input.use { i -> out.outputStream().use { o -> i.copyTo(o, 1 shl 20) } }
        } catch (e: IOException) {
            out.delete()
            if (isNoSpace(e)) throw NoSpaceException(e.message ?: "ENOSPC")
            throw e
        }
        return out
    }

    fun isNoSpace(t: Throwable?): Boolean {
        var c = t
        while (c != null) {
            val m = c.message ?: ""
            if (m.contains("ENOSPC", true) || m.contains("No space left", true)) return true
            c = c.cause
        }
        return false
    }

    class NoSpaceException(message: String) : IOException(message)

    fun delete(context: Context, path: String): Boolean {
        val f = File(path)
        require(isOwned(context, f)) { "Refusing to delete a file outside $DIR_NAME: $path" }
        return !f.exists() || f.delete()
    }

    fun deleteAll(context: Context): Int =
        dir(context).listFiles()?.count { it.isFile && it.delete() } ?: 0

    /**
     * POC helper: streams a copy of an output (never the source) into
     * Movies/CombatFlux POC so it can be inspected on a computer.
     * Android 10+ (scoped storage, no permission needed).
     */
    fun saveCopyToMovies(context: Context, path: String): String {
        val f = File(path)
        require(isOwned(context, f) && f.exists()) { "Not a compressed output: $path" }
        if (Build.VERSION.SDK_INT < 29) {
            throw UnsupportedOperationException(
                "Save copy needs Android 10+. Use: adb pull ${f.absolutePath}")
        }
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, f.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/CombatFlux POC")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values,
        ) ?: throw IOException("MediaStore insert failed")
        try {
            val os = resolver.openOutputStream(uri) ?: throw IOException("Cannot open $uri")
            os.use { out -> FileInputStream(f).use { it.copyTo(out, 1 shl 20) } } // 1 MiB buffer
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri.toString()
    }
}
