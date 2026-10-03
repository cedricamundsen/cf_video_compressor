import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Settings for exactly one encode attempt (decided by the Dart planner).
struct CompressArgs {
    let attempt: Int
    let videoBitrate: Int
    /// 0 = do not write an audio track.
    let audioBitrate: Int
    /// Output short side in px, or nil to keep the source size.
    let targetShortSide: Int?
    /// Frame-rate cap, or nil to keep the source frame rate.
    let maxFrameRate: Double?
    let toneMapHdrToSdr: Bool
    /// iOS has no true CBR for H.264 through AVAssetWriter; VBR is used.
    let cbr: Bool
}

enum JobError: Error {
    case unsupported(String)
    case unreadable(String)
    case failed(String)
    case noSpace(String)
}

/// One AVFoundation transcode: source file -> H.264/AAC MP4 at [output]
/// (iOS side of CompressionJob.kt).
///
/// AVAssetReader decodes with a video composition that (1) applies the
/// track's rotation so the output is upright (rotation 0), (2) scales so the
/// short side is 720/540 when the planner asks for it, (3) emits at most
/// [maxFrameRate] frames per second (same speed, timestamps kept) and (4)
/// converts HDR (HLG/PQ, 10-bit) to SDR BT.709. AVAssetWriter encodes with
/// the hardware H.264 encoder and AAC. Samples stream one buffer at a time;
/// the file is never held in memory. Exactly one attempt - retries are Dart's.
final class CompressionJob {
    let source: URL
    let output: URL
    let args: CompressArgs

    private let onProgress: (_ attempt: Int, _ percent: Int, _ state: String) -> Void
    private let onDone: (_ error: Error?, _ elapsedMs: Int64, _ cancelled: Bool) -> Void

    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private let videoQueue = DispatchQueue(label: "com.combatflux.cf_video_compressor.video")
    private let audioQueue = DispatchQueue(label: "com.combatflux.cf_video_compressor.audio")
    private var startedAt = Date()
    private var durationSeconds: Double = 0
    private var lastPercent = -1
    private var lastProgressAt = Date.distantPast
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private(set) var wroteAudio = false
    private(set) var outputFrameRate: Double = 0

    init(source: URL,
         output: URL,
         args: CompressArgs,
         onProgress: @escaping (_ attempt: Int, _ percent: Int, _ state: String) -> Void,
         onDone: @escaping (_ error: Error?, _ elapsedMs: Int64, _ cancelled: Bool) -> Void) {
        self.source = source
        self.output = output
        self.args = args
        self.onProgress = onProgress
        self.onDone = onDone
    }

    var elapsedMs: Int64 { Int64(Date().timeIntervalSince(startedAt) * 1000) }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    // MARK: - start

    /// Called on the main thread; all work happens on background queues.
    func start() {
        startedAt = Date()
        // A little background time so a short app switch does not kill the
        // export. Long encodes still need the app in the foreground (iOS
        // suspends hardware encoding in the background).
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "cf_compress") { [weak self] in
            self?.endBackgroundTask()
        }
        emitProgress(0, state: "running", force: true)
        videoQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.setUpAndRun()
            } catch {
                self.fail(error)
            }
        }
    }

    private func setUpAndRun() throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            try VideoProbe.load(asset, keys: ["duration", "tracks"])
        } catch {
            throw JobError.unreadable("\(error)")
        }
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw JobError.unsupported("The file has no video track")
        }
        durationSeconds = CMTimeGetSeconds(asset.duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw JobError.unsupported("Unknown duration")
        }

        // --- geometry: upright display size, then the planner's short side ---
        let natural = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let displayRect = CGRect(origin: .zero, size: natural).applying(transform)
        let displayW = abs(displayRect.width)
        let displayH = abs(displayRect.height)
        guard displayW >= 2, displayH >= 2 else { throw JobError.unsupported("Invalid video size") }
        var outW = displayW
        var outH = displayH
        let shortSide = min(displayW, displayH)
        if let target = args.targetShortSide, CGFloat(target) < shortSide {
            let s = CGFloat(target) / shortSide
            outW = displayW * s
            outH = displayH * s
        }
        let renderW = CompressionJob.even(outW)
        let renderH = CompressionJob.even(outH)
        let upright = transform.concatenating(
            CGAffineTransform(translationX: -displayRect.origin.x, y: -displayRect.origin.y))
        let layerTransform = upright.concatenating(
            CGAffineTransform(scaleX: CGFloat(renderW) / displayW, y: CGFloat(renderH) / displayH))

        // --- frame rate: keep the source rate, cap at maxFrameRate ---
        let sourceFps = videoTrack.nominalFrameRate > 0 ? Double(videoTrack.nominalFrameRate) : 30
        var fps = sourceFps
        if let cap = args.maxFrameRate, cap > 0, sourceFps > cap + 0.5 { fps = cap }
        outputFrameRate = fps

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: renderW, height: renderH)
        composition.frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        if args.toneMapHdrToSdr {
            // SDR BT.709 output: AVFoundation converts HDR (HLG/PQ) sources.
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(layerTransform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        // --- audio format: AAC, mono/stereo, 44.1/48 kHz ---
        var audioTrack: AVAssetTrack?
        var channels = 2
        var sampleRate = 44100
        if args.audioBitrate > 0, let a = asset.tracks(withMediaType: .audio).first {
            audioTrack = a
            if let first = a.formatDescriptions.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first as! CMAudioFormatDescription)?.pointee {
                channels = asbd.mChannelsPerFrame <= 1 ? 1 : 2
                sampleRate = Int(asbd.mSampleRate) == 48000 ? 48000 : 44100
            }
        }

        // --- writer ---
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw JobError.failed("Cannot create output: \(error.localizedDescription)")
        }
        writer.shouldOptimizeForNetworkUse = true // index at the front (fast range seeking)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: renderW,
            AVVideoHeightKey: renderH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: args.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoAllowFrameReorderingKey: true,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw JobError.unsupported("H.264 \(renderW)x\(renderH) is not supported by this device")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw JobError.unsupported("Cannot add the video encoder") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioTrack != nil {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: channels,
                AVSampleRateKey: sampleRate,
                AVEncoderBitRateKey: args.audioBitrate,
                AVChannelLayoutKey: layoutData,
            ]
            if writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
        }

        // --- reader (only the outputs the writer will consume) ---
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw JobError.unreadable("Cannot read the source: \(error.localizedDescription)")
        }
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw JobError.unsupported("Cannot decode this video") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let a = audioTrack, audioInput != nil {
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
            ]
            let o = AVAssetReaderTrackOutput(track: a, outputSettings: pcm)
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) {
                reader.add(o)
                audioOutput = o
            }
        }
        if audioOutput == nil { audioInput = nil } // writer input without data would never finish
        wroteAudio = audioInput != nil

        lock.lock()
        self.reader = reader
        self.writer = writer
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { throw JobError.failed("cancelled") }

        guard writer.startWriting() else {
            throw writer.error.map { JobError.failed($0.localizedDescription) } ?? JobError.failed("startWriting failed")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error.map { JobError.unreadable($0.localizedDescription) } ?? JobError.unreadable("startReading failed")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        group.enter()
        pump(input: videoInput, output: videoOutput, queue: videoQueue, isVideo: true, group: group)
        if let ai = audioInput, let ao = audioOutput {
            group.enter()
            pump(input: ai, output: ao, queue: audioQueue, isVideo: false, group: group)
        }
        group.notify(queue: videoQueue) { [weak self] in self?.complete() }
    }

    /// Moves samples reader -> writer while the encoder accepts them.
    private func pump(input: AVAssetWriterInput,
                      output: AVAssetReaderOutput,
                      queue: DispatchQueue,
                      isVideo: Bool,
                      group: DispatchGroup) {
        var done = false
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self = self else { return }
            if done { return }
            while input.isReadyForMoreMediaData {
                let keepGoing: Bool = autoreleasepool {
                    if self.isCancelled || self.reader?.status != .reading { return false }
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    if isVideo {
                        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                        if t.isFinite && self.durationSeconds > 0 {
                            self.emitProgress(Int(min(99, max(0, t / self.durationSeconds * 100))), state: "running")
                        }
                    }
                    return input.append(sample)
                }
                if !keepGoing {
                    done = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }

    private func complete() {
        guard let reader = reader, let writer = writer else { return }
        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            finish(error: nil, cancelled: true)
            return
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            finish(error: reader.error ?? JobError.failed("Decoding failed"), cancelled: false)
            return
        }
        if writer.status == .failed {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: output)
            finish(error: writer.error ?? JobError.failed("Encoding failed"), cancelled: false)
            return
        }
        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            if writer.status == .completed && !self.isCancelled {
                self.emitProgress(100, state: "running", force: true)
                self.finish(error: nil, cancelled: false)
            } else {
                try? FileManager.default.removeItem(at: self.output)
                self.finish(error: self.isCancelled ? nil : (writer.error ?? JobError.failed("Encoding did not complete")),
                            cancelled: self.isCancelled)
            }
        }
    }

    // MARK: - cancel / finish

    /// Stops the export; the partial output is deleted and onDone reports
    /// cancelled. Returns false when nothing is running.
    func cancel() -> Bool {
        lock.lock()
        if finished || cancelled {
            lock.unlock()
            return false
        }
        cancelled = true
        let r = reader
        lock.unlock()
        r?.cancelReading() // pumps see no more samples -> complete() cleans up
        if r == nil {
            // Not started yet: setUpAndRun() notices the flag and fails fast.
        }
        return true
    }

    private func fail(_ error: Error) {
        reader?.cancelReading()
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: output)
        let wasCancelled = isCancelled
        finish(error: wasCancelled ? nil : error, cancelled: wasCancelled)
    }

    private func finish(error: Error?, cancelled: Bool) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        let elapsed = elapsedMs
        DispatchQueue.main.async {
            self.endBackgroundTask()
            self.onDone(error, elapsed, cancelled)
        }
    }

    private func endBackgroundTask() {
        let run = {
            if self.backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    /// Real progress from the written timestamps; at most ~4 events/s.
    private func emitProgress(_ percent: Int, state: String, force: Bool = false) {
        let now = Date()
        lock.lock()
        let changed = percent != lastPercent
        let due = now.timeIntervalSince(lastProgressAt) >= 0.25
        if !force && !(changed && due) {
            lock.unlock()
            return
        }
        lastPercent = percent
        lastProgressAt = now
        lock.unlock()
        let attempt = args.attempt
        DispatchQueue.main.async { self.onProgress(attempt, percent, state) }
    }

    static func even(_ v: CGFloat) -> Int {
        max(2, Int((v / 2).rounded()) * 2)
    }
}
