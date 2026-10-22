import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case alreadyRecording, notRecording
    case permissionDenied
    case noDisplay
    case noFrames
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "No recording is in progress."
        case .permissionDenied:
            return "Screen recording permission is missing. Enable ScreenRecz in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch the app."
        case .noDisplay: return "No display is available to record."
        case .noFrames: return "The recording contained no video frames, so nothing was saved."
        case .writer(let m): return "Could not write the recording: \(m)"
        }
    }
}

/// Receives ScreenCaptureKit buffers and owns the AVAssetWriter. All state is touched only on `queue`.
final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "screen-recz.capture", qos: .userInteractive)
    var onStreamError: (@Sendable (Error) -> Void)?

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let mic: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var lastVideoPTS = CMTime.invalid
    private var stopRequested = false

    init(url: URL, width: Int, height: Int, systemAudio: Bool, mic: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let bitrate = max(2_000_000, 6_000_000 * width * height / (1920 * 1080))
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        func aac(channels: Int, bitrate: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        self.systemAudio = systemAudio ? aac(channels: 2, bitrate: 128_000) : nil
        self.mic = mic ? aac(channels: 1, bitrate: 96_000) : nil
        if let a = self.systemAudio { writer.add(a) }
        if let m = self.mic { writer.add(m) }

        guard writer.startWriting() else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
    }

    // MARK: SCStreamOutput (runs on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopRequested, sb.isValid, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sb), CMSampleBufferGetImageBuffer(sb) != nil else { return }
            let pts = sb.presentationTimeStamp
            if sessionStart == nil {
                writer.startSession(atSourceTime: pts)
                sessionStart = pts
            }
            guard video.isReadyForMoreMediaData, video.append(sb) else { return }
            lastVideoPTS = pts
        case .audio:
            appendAudio(sb, to: systemAudio)
        case .microphone:
            appendAudio(sb, to: mic)
        @unknown default:
            break
        }
    }

    /// Entry point for buffers from `MicCapture`; hops onto `queue` like the SCStream outputs.
    func appendMic(_ sb: CMSampleBuffer) {
        queue.async { [self] in
            guard !stopRequested, writer.status == .writing else { return }
            appendAudio(sb, to: mic)
        }
    }

    private func appendAudio(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, let start = sessionStart, sb.numSamples > 0,
              sb.presentationTimeStamp >= start, input.isReadyForMoreMediaData else { return }
        input.append(sb)
    }

    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let list = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = list.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    // MARK: Finish

    /// Closes the file with at least `stopTime` of duration. Throws `.noFrames` (and deletes the file) if empty.
    func finish(at stopTime: CMTime) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                stopRequested = true
                guard sessionStart != nil else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: writer.outputURL)
                    cont.resume(throwing: RecorderError.noFrames)
                    return
                }
                [video, systemAudio, mic].forEach { $0?.markAsFinished() }
                writer.endSession(atSourceTime: lastVideoPTS.isValid ? CMTimeMaximum(stopTime, lastVideoPTS) : stopTime)
                writer.finishWriting { [writer] in
                    if writer.status == .completed {
                        cont.resume()
                    } else {
                        cont.resume(throwing: RecorderError.writer(writer.error?.localizedDescription ?? "finishWriting failed"))
                    }
                }
            }
        }
    }
}

@MainActor final class Recorder {
    private(set) var isRecording = false
    /// Final file of the last recording that was salvaged after an unexpected stop.
    private(set) var lastOutputURL: URL?
    var onUnexpectedStop: ((Error) -> Void)?

    private var stream: SCStream?
    private var sink: CaptureSink?
    private var rawURL: URL?
    private var finalURL: URL?
    private var micCapture: MicCapture?

    func start(_ options: RecordingOptions) async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw Self.map(error)
        }
        guard let display = content.displays.first(where: { $0.displayID == options.displayID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }

        let pid = getpid()
        let app = content.applications.first { $0.processID == pid }
        let filter: SCContentFilter
        if let app {
            let overlay = options.overlayWindowID.flatMap { id in content.windows.first { $0.windowID == id } }
            filter = SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: overlay.map { [$0] } ?? [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        // Output size: native pixels, shrunk to fit 1920x1080, never upscaled, even dimensions.
        let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : 1
        let pxW = CGFloat(display.width) * scale, pxH = CGFloat(display.height) * scale
        let fit = min(1, 1920 / pxW, 1080 / pxH)
        let width = max(2, Int(pxW * fit) & ~1), height = max(2, Int(pxH * fit) & ~1)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.capturesAudio = options.captureSystemAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // Echo-cancelled mic goes through MicCapture; if it can't start, fall back to ScreenCaptureKit's mic.
        var micCapture: MicCapture?
        if options.captureMicrophone && options.echoCancellation {
            let capture = MicCapture(deviceUID: options.microphoneDeviceID)
            do {
                try capture.start()
                micCapture = capture
            } catch {
                capture.stop()
            }
        }
        let scMic = options.captureMicrophone && micCapture == nil
        config.captureMicrophone = scMic
        config.microphoneCaptureDeviceID = options.microphoneDeviceID

        let final = RecordingPaths.newRecordingURL()
        let raw = final.deletingLastPathComponent().appendingPathComponent(".\(final.lastPathComponent).partial.mov")
        let sink = try CaptureSink(url: raw, width: width, height: height,
                                   systemAudio: options.captureSystemAudio, mic: options.captureMicrophone)
        sink.onStreamError = { [weak self] error in
            Task { @MainActor in await self?.handleUnexpectedStop(error) }
        }
        micCapture?.onBuffer = { [weak sink] sb in sink?.appendMic(sb) }  // dropped until the session starts

        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            if options.captureSystemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
            if scMic { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue) }
            try await stream.startCapture()
        } catch {
            micCapture?.stop()
            try? await sink.finish(at: .zero)  // cancels the writer and removes the temp file
            throw Self.map(error)
        }

        self.stream = stream
        self.sink = sink
        self.micCapture = micCapture
        rawURL = raw
        finalURL = final
        lastOutputURL = nil
        isRecording = true
    }

    func stop() async throws -> URL {
        guard isRecording, let stream else { throw RecorderError.notRecording }
        isRecording = false
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        try? await stream.stopCapture()
        return try await finishAndFinalize(stopTime: stopTime)
    }

    private func handleUnexpectedStop(_ error: Error) async {
        guard isRecording else { return }
        isRecording = false
        lastOutputURL = try? await finishAndFinalize(stopTime: CMClockGetTime(CMClockGetHostTimeClock()))
        onUnexpectedStop?(error)
    }

    private func finishAndFinalize(stopTime: CMTime) async throws -> URL {
        guard let sink, let raw = rawURL, let final = finalURL else { throw RecorderError.notRecording }
        defer { self.stream = nil; self.sink = nil; rawURL = nil; finalURL = nil }
        micCapture?.stop()
        micCapture = nil
        try await sink.finish(at: stopTime)
        let result = try await Finalizer.finalize(raw: raw, to: final)
        if result != raw { try? FileManager.default.removeItem(at: raw) }
        return result
    }

    private static func map(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
            return RecorderError.permissionDenied
        }
        return error
    }
}

/// Records the main display with mic + system audio for `seconds`, prints `SELFTEST OK <path>` or `SELFTEST FAIL <error>`.
@MainActor func runSelfTest(seconds: Double) async {
    let recorder = Recorder()
    do {
        try await recorder.start(RecordingOptions(displayID: CGMainDisplayID(), captureMicrophone: true,
                                                  microphoneDeviceID: nil, captureSystemAudio: true, echoCancellation: true,
                                                  overlayWindowID: nil))
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        let url = try await recorder.stop()
        print("SELFTEST OK \(url.path)")
    } catch {
        print("SELFTEST FAIL \(error.localizedDescription)")
    }
}
