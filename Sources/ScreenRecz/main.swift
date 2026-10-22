import AVFoundation
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Retained for the lifetime of the process (NSApplication.delegate is weak).
var appDelegate: AppDelegate?

if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    let seconds = CommandLine.arguments.dropFirst(i + 1).first.flatMap(Double.init) ?? 5
    Task { @MainActor in
        _ = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await runSelfTest(seconds: seconds)
        exit(0)
    }
} else {
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
    }
}

app.run()
