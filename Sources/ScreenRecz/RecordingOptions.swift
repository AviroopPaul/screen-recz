import CoreGraphics
import Foundation

/// What to capture. Built by the UI, consumed by `Recorder`.
struct RecordingOptions {
    var displayID: CGDirectDisplayID
    var captureMicrophone: Bool
    /// `AVCaptureDevice.uniqueID` of the mic; nil = system default input.
    var microphoneDeviceID: String?
    var captureSystemAudio: Bool
    /// Capture the mic through voice processing (echo cancellation) instead of ScreenCaptureKit.
    var echoCancellation: Bool
    /// Window number of the camera overlay panel. Every other window owned by this app
    /// (menus, status item, alerts) is hidden from the recording; this one stays visible.
    var overlayWindowID: CGWindowID?
}

enum RecordingPaths {
    /// ~/Pictures/screen-recz, created on demand.
    static var folder: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/screen-recz", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "Recording 2026-10-21 at 14.03.22.mp4"
    static func newRecordingURL(date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("Recording \(f.string(from: date)).mp4")
    }
}
