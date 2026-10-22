import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Microphone capture through Apple's voice-processing I/O (acoustic echo cancellation, noise suppression, AGC).
/// Delivers mono 48 kHz Float32 sample buffers stamped on the host clock, like ScreenCaptureKit.
final class MicCapture: @unchecked Sendable {
    /// Called on an audio thread for every converted buffer.
    var onBuffer: ((CMSampleBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private let deviceUID: String?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private var formatDescription: CMAudioFormatDescription?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var scratch: AVAudioPCMBuffer?
    private var nextPTS = CMTime.invalid  // running PTS, used only when a tap time has no valid host time
    private var running = false

    init(deviceUID: String?) {
        self.deviceUID = deviceUID
    }

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        if let deviceUID, let id = Self.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var dev = id
            // Failure is fine: we silently keep the default input.
            _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)

        // Voice processing needs the output side in the graph; keep it silent and unconnected to the input.
        engine.mainMixerNode.outputVolume = 0

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.writer("Microphone has no usable input format.")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.process(buffer, time)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onBuffer = nil
    }

    // MARK: Tap

    private func process(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard buffer.frameLength > 0 else { return }
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converterInput = buffer.format
        }
        guard let converter else { return }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 32
        if scratch == nil || scratch!.frameCapacity < capacity {
            scratch = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
        }
        guard let out = scratch else { return }
        out.frameLength = 0

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }

        let pts: CMTime
        if time.isHostTimeValid {
            pts = CMClockMakeHostTimeFromSystemUnits(time.hostTime)
            nextPTS = CMTimeAdd(pts, CMTime(value: CMTimeValue(out.frameLength), timescale: 48_000))
        } else if nextPTS.isValid {
            pts = nextPTS
            nextPTS = CMTimeAdd(pts, CMTime(value: CMTimeValue(out.frameLength), timescale: 48_000))
        } else {
            return  // no timestamp reference yet
        }
        if let sb = Self.sampleBuffer(from: out, format: &formatDescription, pts: pts) {
            onBuffer?(sb)
        }
    }

    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, format: inout CMAudioFormatDescription?, pts: CMTime) -> CMSampleBuffer? {
        if format == nil {
            var desc: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription,
                                                 layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                 extensions: nil, formatDescriptionOut: &desc) == noErr else { return nil }
            format = desc
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                   sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sb) == noErr, let sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sb, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList) == noErr else { return nil }
        return sb
    }

    // MARK: Device lookup

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }
}
