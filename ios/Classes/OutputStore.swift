import Foundation

/// Owns the plugin's temp directories (iOS side of OutputStore.kt):
///   <tmp>/cf_compress/cf_<epochMs>_a<attempt>.mp4   compressed outputs + source copies
///   <tmp>/cf_picked/cf_<epochMs>_pick.<ext>          copies of picker results
/// App-private, never the source's location, deletable by name/pattern. iOS may
/// also purge tmp under storage pressure. Picker copies live in their own
/// folder because the preparer clears cf_compress before every run.
enum OutputStore {
    private static let compressDirName = "cf_compress"
    private static let pickedDirName = "cf_picked"

    static func dir() -> URL { ensure(compressDirName) }
    static func pickedDir() -> URL { ensure(pickedDirName) }

    private static func ensure(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func newOutputFile(attempt: Int) -> URL {
        dir().appendingPathComponent("cf_\(nowMs())_a\(attempt).mp4")
    }

    /// Free bytes for important writes on the volume holding the temp dir
    /// (required-reason API: disk space, reason E174.1 - checked before writing).
    static func availableBytes() -> Int64 {
        let values = try? dir().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? -1)
    }

    /// True only for our own cf_* files directly inside one of our folders.
    static func isOwned(_ url: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let owned = [dir(), pickedDir()].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        return owned.contains(parent) && url.lastPathComponent.hasPrefix("cf_")
    }

    static func delete(path: String) throws -> Bool {
        let url = URL(fileURLWithPath: path)
        guard isOwned(url) else {
            throw NSError(domain: "cf_video_compressor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Refusing to delete a file outside the plugin temp folders: \(path)"])
        }
        if !FileManager.default.fileExists(atPath: url.path) { return true }
        try FileManager.default.removeItem(at: url)
        return true
    }

    /// Deletes every file in cf_compress (not the picker copies). Returns the count.
    static func deleteAll() -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir(), includingPropertiesForKeys: nil)) ?? []
        var n = 0
        for f in files where (try? fm.removeItem(at: f)) != nil { n += 1 }
        return n
    }

    /// Deletes earlier picker copies (keeps [keep]).
    static func deletePicked(except keep: URL? = nil) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: pickedDir(), includingPropertiesForKeys: nil)) ?? []
        for f in files where f.standardizedFileURL != keep?.standardizedFileURL {
            try? fm.removeItem(at: f)
        }
    }

    enum CopyError: Error {
        case noSpace(String)
        case unreadable(String)
    }

    /// Copies a (small enough) source into cf_compress so Dart can read it as
    /// a plain file. FileManager copies on disk (APFS may clone); nothing is
    /// loaded into memory. The source is only read.
    static func copySourceToTemp(source: URL, expectedBytes: Int64) throws -> URL {
        let margin: Int64 = 16 * 1024 * 1024
        if expectedBytes > 0 && availableBytes() < expectedBytes + margin {
            throw CopyError.noSpace("Need \(expectedBytes + margin) bytes, have \(availableBytes())")
        }
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension.lowercased()
        let out = dir().appendingPathComponent("cf_\(nowMs())_src.\(ext)")
        do {
            try FileManager.default.copyItem(at: source, to: out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            if isNoSpace(error) { throw CopyError.noSpace(error.localizedDescription) }
            throw CopyError.unreadable(error.localizedDescription)
        }
        return out
    }

    static func isNoSpace(_ error: Error?) -> Bool {
        guard let e = error as NSError? else { return false }
        if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
        if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return true }
        if e.domain == "AVFoundationErrorDomain" && e.code == -11807 { return true } // AVError.diskFull
        if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isNoSpace(under) }
        return false
    }
}
