import AVFoundation
import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// iOS side of CfVideoCompressorPlatform (same channels and methods as
/// CfVideoCompressorPlugin.kt):
///   pickVideo, getVideoInfo, compress, cancel, deleteOutput, deleteAllOutputs,
///   tempDirectory, availableTempBytes, copySourceToTemp, saveCopyToMovies
/// Events (com.combatflux/cf_video_compressor/progress): {attempt, percent, state}
/// Only strings and numbers cross the channel; video bytes never do.
public class CfVideoCompressorPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, PHPickerViewControllerDelegate {
    private var eventSink: FlutterEventSink?
    private var pendingPick: FlutterResult?
    private var job: CompressionJob?
    private let io = DispatchQueue(label: "com.combatflux.cf_video_compressor.io", qos: .userInitiated)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CfVideoCompressorPlugin()
        let methods = FlutterMethodChannel(name: "com.combatflux/cf_video_compressor",
                                           binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        let events = FlutterEventChannel(name: "com.combatflux/cf_video_compressor/progress",
                                         binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    // MARK: - EventChannel

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Methods

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "pickVideo":
            pickVideo(result)
        case "getVideoInfo":
            guard let uri = args["uri"] as? String else { return result(badArgs("uri is required")) }
            background(result, errorCode: "SOURCE_UNREADABLE") { try VideoProbe.probe(uri) }
        case "compress":
            compress(args, result)
        case "cancel":
            result(job?.cancel() ?? false)
        case "deleteOutput":
            guard let path = args["path"] as? String else { return result(badArgs("path is required")) }
            if let j = job, j.output.path == path {
                return result(FlutterError(code: "BUSY", message: "That output is still being written", details: nil))
            }
            background(result, errorCode: "DELETE_FAILED") { try OutputStore.delete(path: path) }
        case "deleteAllOutputs":
            if job != nil { return result(FlutterError(code: "BUSY", message: "A compression is running", details: nil)) }
            background(result, errorCode: "DELETE_FAILED") { OutputStore.deleteAll() }
        case "tempDirectory":
            result(OutputStore.dir().path)
        case "availableTempBytes":
            background(result, errorCode: "IO_FAILED") { OutputStore.availableBytes() }
        case "copySourceToTemp":
            guard let uri = args["uri"] as? String else { return result(badArgs("uri is required")) }
            let expected = (args["expectedBytes"] as? NSNumber)?.int64Value ?? -1
            io.async {
                do {
                    let f = try OutputStore.copySourceToTemp(source: VideoProbe.parse(uri), expectedBytes: expected)
                    let size = OutputStore.fileSize(f)
                    DispatchQueue.main.async { result(["path": f.path, "sizeBytes": size]) }
                } catch OutputStore.CopyError.noSpace(let m) {
                    DispatchQueue.main.async { result(FlutterError(code: "NO_SPACE", message: m, details: nil)) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "SOURCE_UNREADABLE", message: "\(error)", details: nil))
                    }
                }
            }
        case "saveCopyToMovies":
            // Android POC helper only (MediaStore). Not offered on iOS.
            result(FlutterError(code: "UNSUPPORTED", message: "saveCopyToMovies is Android-only", details: nil))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func badArgs(_ message: String) -> FlutterError {
        FlutterError(code: "BAD_ARGS", message: message, details: nil)
    }

    /// Runs blocking I/O off the main thread; replies on the main thread.
    private func background(_ result: @escaping FlutterResult, errorCode: String, _ block: @escaping () throws -> Any?) {
        io.async {
            do {
                let value = try block()
                DispatchQueue.main.async { result(value) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: errorCode, message: "\(error)", details: nil))
                }
            }
        }
    }

    // MARK: - Picker

    /// System photo picker (no photo-library permission needed). The ORIGINAL
    /// file representation is copied into <tmp>/cf_picked (streamed on disk,
    /// never into memory) because the picker's file only lives during the
    /// callback. Returns the copy's path, or nil when the user cancels.
    private func pickVideo(_ result: @escaping FlutterResult) {
        if pendingPick != nil {
            return result(FlutterError(code: "BUSY", message: "Picker already open", details: nil))
        }
        guard let presenter = CfVideoCompressorPlugin.topViewController() else {
            return result(FlutterError(code: "NO_ACTIVITY", message: "No view controller to present the picker", details: nil))
        }
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current // no transcoding by Photos
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        pendingPick = result
        presenter.present(picker, animated: true)
    }

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = pendingPick else { return }
        pendingPick = nil
        guard let item = results.first?.itemProvider else {
            result(nil) // dismissed
            return
        }
        let type = item.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true }
            ?? UTType.movie.identifier
        item.loadFileRepresentation(forTypeIdentifier: type) { url, error in
            guard let url = url else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "SOURCE_UNREADABLE",
                                        message: error?.localizedDescription ?? "The video could not be loaded",
                                        details: nil))
                }
                return
            }
            // Copy now (synchronously): the provided file is deleted after this block.
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
            let dest = OutputStore.pickedDir().appendingPathComponent("cf_\(OutputStore.nowMs())_pick.\(ext)")
            let size = OutputStore.fileSize(url)
            if size > 0 && OutputStore.availableBytes() < size + 64 * 1024 * 1024 {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_SPACE", message: "Not enough free space to open this video", details: nil))
                }
                return
            }
            do {
                OutputStore.deletePicked() // earlier picks are no longer needed
                try FileManager.default.copyItem(at: url, to: dest)
                DispatchQueue.main.async { result(dest.path) }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                let code = OutputStore.isNoSpace(error) ? "NO_SPACE" : "SOURCE_UNREADABLE"
                DispatchQueue.main.async {
                    result(FlutterError(code: code, message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: - Compression

    private func compress(_ args: [String: Any], _ result: @escaping FlutterResult) {
        if job != nil {
            return result(FlutterError(code: "BUSY", message: "A compression is already running", details: nil))
        }
        guard let uri = args["uri"] as? String else { return result(badArgs("uri is required")) }
        guard let videoBitrate = (args["videoBitrate"] as? NSNumber)?.intValue, videoBitrate > 0 else {
            return result(badArgs("videoBitrate must be > 0"))
        }
        let a = CompressArgs(
            attempt: (args["attempt"] as? NSNumber)?.intValue ?? 1,
            videoBitrate: videoBitrate,
            audioBitrate: (args["audioBitrate"] as? NSNumber)?.intValue ?? 64000,
            targetShortSide: (args["targetShortSide"] as? NSNumber)?.intValue,
            maxFrameRate: (args["maxFrameRate"] as? NSNumber)?.doubleValue,
            toneMapHdrToSdr: (args["toneMapHdrToSdr"] as? Bool) ?? true,
            cbr: (args["bitrateMode"] as? String) == "cbr")
        // Fail fast (before touching the encoder) when the output cannot fit.
        let required = (args["requiredBytes"] as? NSNumber)?.int64Value ?? 0
        let free = OutputStore.availableBytes()
        if required > 0 && free < required {
            return result(FlutterError(code: "NO_SPACE", message: "Need \(required) bytes free, have \(free)", details: nil))
        }
        let source = VideoProbe.parse(uri)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return result(FlutterError(code: "SOURCE_UNREADABLE", message: "File not found: \(source.path)", details: nil))
        }
        let output = OutputStore.newOutputFile(attempt: a.attempt)
        let newJob = CompressionJob(
            source: source,
            output: output,
            args: a,
            onProgress: { [weak self] attempt, percent, state in
                self?.eventSink?(["attempt": attempt, "percent": percent, "state": state])
            },
            onDone: { [weak self] error, elapsedMs, cancelled in
                guard let self = self else { return }
                let finishedJob = self.job
                self.job = nil
                if cancelled {
                    result(FlutterError(code: "CANCELLED", message: "Cancelled; partial output deleted", details: nil))
                } else if let error = error {
                    result(FlutterError(code: CfVideoCompressorPlugin.classify(error),
                                        message: "\(error)",
                                        details: ["elapsedMs": elapsedMs]))
                } else {
                    self.background(result, errorCode: "OUTPUT_UNREADABLE") {
                        try self.describeOutput(output, args: a, job: finishedJob, elapsedMs: elapsedMs)
                    }
                }
            })
        job = newJob
        newJob.start()
    }

    /// Maps failures to the categories the app shows messages for.
    static func classify(_ error: Error) -> String {
        if OutputStore.isNoSpace(error) { return "NO_SPACE" }
        switch error {
        case JobError.unsupported: return "UNSUPPORTED_INPUT"
        case JobError.unreadable: return "SOURCE_UNREADABLE"
        case JobError.noSpace: return "NO_SPACE"
        default: break
        }
        let e = error as NSError
        if e.domain == "AVFoundationErrorDomain" {
            switch e.code {
            case -11828, -11829, -11833, -11821, -11832, -11834, -11838:
                // fileFormatNotRecognized, failedToParse, decoderNotFound,
                // decodeFailed, applicationIsNotAuthorizedToUseDevice?,
                // decoderTemporarilyUnavailable, operationNotSupportedForAsset
                return "UNSUPPORTED_INPUT"
            case -11800:
                return "EXPORT_FAILED" // unknown
            default:
                break
            }
        }
        if e.domain == NSCocoaErrorDomain && (e.code == NSFileReadNoSuchFileError || e.code == NSFileReadNoPermissionError) {
            return "SOURCE_UNREADABLE"
        }
        return "EXPORT_FAILED"
    }

    /// Re-probes the finished file so the report shows what is really on disk.
    private func describeOutput(_ output: URL, args: CompressArgs, job: CompressionJob?, elapsedMs: Int64) throws -> [String: Any] {
        let p = try VideoProbe.probe(output.path)
        var out: [String: Any] = [
            "attempt": args.attempt,
            "outputPath": output.path,
            "outputSizeBytes": OutputStore.fileSize(output),
            "outputWidth": p["width"] ?? 0,
            "outputHeight": p["height"] ?? 0,
            "outputRotationDegrees": p["rotationDegrees"] ?? 0,
            "outputDurationMs": p["durationMs"] ?? 0,
            "videoEncoderName": "AVAssetWriter H.264 (VideoToolbox)",
            "videoConversion": "transcoded",
            "audioConversion": (job?.wroteAudio ?? false) ? "transcoded" : "n/a",
            "elapsedMs": elapsedMs,
        ]
        if let fps = p["frameRate"] { out["outputFrameRate"] = fps }
        if let v = p["videoMime"] { out["outputVideoMime"] = v }
        if let a = p["audioMime"] { out["outputAudioMime"] = a }
        if let vb = p["videoBitrate"] { out["averageVideoBitrate"] = vb }
        if let ab = p["audioBitrate"] { out["averageAudioBitrate"] = ab }
        if job?.wroteAudio == true { out["audioEncoderName"] = "AVAssetWriter AAC" }
        return out
    }
}
