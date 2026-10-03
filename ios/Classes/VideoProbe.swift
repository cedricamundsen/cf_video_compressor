import AVFoundation
import CoreMedia
import Foundation

/// iOS side of VideoProbe.kt: container/track metadata without decoding frames
/// and without loading the file. Returns the same keys as Android (coded
/// width/height + rotationDegrees, MediaFormat-style mime strings and
/// colorTransfer 6 = PQ/HDR10, 7 = HLG). Call off the main thread.
enum VideoProbe {

    /// Accepts file:// URLs or absolute paths (iOS sources are always files).
    static func parse(_ value: String) -> URL {
        if value.hasPrefix("file://"), let u = URL(string: value) { return u }
        return URL(fileURLWithPath: value)
    }

    enum ProbeError: Error {
        case notFound(String)
        case unreadable(String)
    }

    /// Loads the given keys synchronously (we are on a background queue).
    static func load(_ asset: AVAsset, keys: [String]) throws {
        let done = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: keys) { done.signal() }
        done.wait()
        for k in keys {
            var error: NSError?
            if asset.statusOfValue(forKey: k, error: &error) != .loaded {
                throw ProbeError.unreadable("Cannot read \(k): \(error?.localizedDescription ?? "unknown")")
            }
        }
    }

    static func probe(_ value: String) throws -> [String: Any] {
        let url = parse(value)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProbeError.notFound("File not found: \(url.path)")
        }
        var out: [String: Any] = [:]
        out["uri"] = url.path
        out["displayName"] = url.lastPathComponent
        let size = OutputStore.fileSize(url)
        out["sizeBytes"] = size

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        try load(asset, keys: ["duration", "tracks"])

        let seconds = CMTimeGetSeconds(asset.duration)
        let durationMs = seconds.isFinite && seconds > 0 ? Int64((seconds * 1000).rounded()) : 0
        out["durationMs"] = durationMs
        if durationMs > 0 && size > 0 {
            out["bitrate"] = Int(Double(size) * 8.0 * 1000.0 / Double(durationMs))
        }

        out["width"] = 0
        out["height"] = 0
        out["rotationDegrees"] = 0
        if let v = asset.tracks(withMediaType: .video).first {
            out["width"] = Int(abs(v.naturalSize.width).rounded())
            out["height"] = Int(abs(v.naturalSize.height).rounded())
            out["rotationDegrees"] = rotationDegrees(v.preferredTransform)
            if v.nominalFrameRate > 0 { out["frameRate"] = Double(v.nominalFrameRate) }
            if v.estimatedDataRate > 0 { out["videoBitrate"] = Int(v.estimatedDataRate) }
            if let first = v.formatDescriptions.first {
                let desc = first as! CMFormatDescription // CoreFoundation type: always bridges
                out["videoMime"] = videoMime(CMFormatDescriptionGetMediaSubType(desc))
                if let transfer = colorTransfer(desc) { out["colorTransfer"] = transfer }
            }
        }

        var hasAudio = false
        if let a = asset.tracks(withMediaType: .audio).first {
            hasAudio = true
            if a.estimatedDataRate > 0 { out["audioBitrate"] = Int(a.estimatedDataRate) }
            if let first = a.formatDescriptions.first {
                let desc = first as! CMAudioFormatDescription
                out["audioMime"] = audioMime(CMFormatDescriptionGetMediaSubType(desc))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    out["audioChannels"] = Int(asbd.mChannelsPerFrame)
                    out["audioSampleRate"] = Int(asbd.mSampleRate)
                }
            }
        }
        out["hasAudio"] = hasAudio
        return out
    }

    /// 0 / 90 / 180 / 270 from a track's preferred transform.
    static func rotationDegrees(_ t: CGAffineTransform) -> Int {
        let degrees = Int((atan2(Double(t.b), Double(t.a)) * 180.0 / Double.pi).rounded())
        return ((degrees % 360) + 360) % 360
    }

    /// Raw four-character code (NOT trimmed: AAC is "aac " with a space).
    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    static func videoMime(_ code: FourCharCode) -> String {
        let cc = fourCC(code)
        switch cc {
        case "avc1", "avc3": return "video/avc"
        case "hvc1", "hev1": return "video/hevc"
        case "dvh1", "dvhe": return "video/dolby-vision"
        case "mp4v": return "video/mp4v-es"
        case "ap4h", "apch", "apcn", "apcs", "apco": return "video/prores"
        default: return "video/\(cc.trimmingCharacters(in: .whitespaces))"
        }
    }

    static func audioMime(_ code: FourCharCode) -> String {
        let cc = fourCC(code)
        switch cc {
        case "aac ": return "audio/mp4a-latm"
        case ".mp3": return "audio/mpeg"
        case "alac": return "audio/alac"
        case "lpcm": return "audio/raw"
        default: return "audio/\(cc.trimmingCharacters(in: .whitespaces))"
        }
    }

    /// Android MediaFormat color transfer values: 6 = ST 2084 (PQ), 7 = HLG.
    static func colorTransfer(_ desc: CMFormatDescription) -> Int? {
        guard let ext = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) else {
            return nil
        }
        let value = ext as? String
        if value == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return 6 }
        if value == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return 7 }
        return nil
    }
}
