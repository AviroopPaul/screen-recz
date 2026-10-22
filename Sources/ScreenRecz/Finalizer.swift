import AVFoundation
import Foundation

/// Remuxes the raw capture .mov into a web-friendly .mp4 (faststart, one mixed AAC track).
enum Finalizer {
    /// Returns the file that holds the recording: `output` normally, or the raw capture
    /// moved next to it with a .mov extension if remuxing failed.
    @discardableResult
    static func finalize(raw: URL, to output: URL) async throws -> URL {
        let fm = FileManager.default
        do {
            try await remux(raw: raw, to: output)
            return output
        } catch {
            try? fm.removeItem(at: output)
        }
        do {
            let export = AVAssetExportSession(asset: AVURLAsset(url: raw), presetName: AVAssetExportPresetPassthrough)
            guard let export else { throw RecorderError.writer("export session unavailable") }
            export.shouldOptimizeForNetworkUse = true
            try await export.export(to: output, as: .mp4)
            return output
        } catch {
            try? fm.removeItem(at: output)
        }
        // Last resort: keep the raw capture so nothing is lost.
        let fallback = output.deletingPathExtension().appendingPathExtension("mov")
        try? fm.removeItem(at: fallback)
        try fm.moveItem(at: raw, to: fallback)
        return fallback
    }

    private static func remux(raw: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: raw)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.writer("no video track")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let formats = try await videoTrack.load(.formatDescriptions)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        videoIn.transform = transform
        reader.add(videoOut)
        writer.add(videoIn)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOut, videoIn)]
        if !audioTracks.isEmpty {
            let mixOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            reader.add(mixOut)
            writer.add(audioIn)
            pairs.append((mixOut, audioIn))
        }

        guard reader.startReading() else {
            throw RecorderError.writer(reader.error?.localizedDescription ?? "startReading failed")
        }
        guard writer.startWriting() else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (i, pair) in pairs.enumerated() {
                let job = PumpJob(output: pair.0, input: pair.1)
                group.addTask { await job.run(queue: DispatchQueue(label: "screen-recz.finalize.\(i)")) }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? RecorderError.writer("read failed")
        }
        // Keep a trailing static screen: the last frame lasts until the original stop time.
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RecorderError.writer("finishWriting failed")
        }
    }
}

/// Copies samples from a reader output into a writer input until exhausted.
private struct PumpJob: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput

    func run(queue: DispatchQueue) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer(), input.append(sample) { continue }
                    input.markAsFinished()
                    cont.resume()
                    return
                }
            }
        }
    }
}
