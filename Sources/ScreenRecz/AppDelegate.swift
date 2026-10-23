import AVFoundation
import AppKit
import Carbon.HIToolbox

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let recorder = Recorder()
    private var overlay: CameraOverlay!
    private var hotkey: Hotkey?
    private var starting = false
    private var finalizing = false
    private var cameraDeniedAlerted = false
    private var recordingStartedAt: Date?
    private var elapsedItem: NSMenuItem?
    private var elapsedTimer: Timer?

    private var isRecording: Bool { recorder.isRecording }

    // MARK: Settings

    private var cameraOn: Bool {
        get { defaults.bool(forKey: "cameraOn") }
        set { defaults.set(newValue, forKey: "cameraOn") }
    }
    private var cameraDeviceID: String? {
        get { defaults.string(forKey: "cameraDeviceID") }
        set { defaults.set(newValue, forKey: "cameraDeviceID") }
    }
    private var micOn: Bool {
        get { defaults.bool(forKey: "micOn") }
        set { defaults.set(newValue, forKey: "micOn") }
    }
    private var micDeviceID: String? {
        get { defaults.string(forKey: "micDeviceID") }
        set { defaults.set(newValue, forKey: "micDeviceID") }
    }
    private var systemAudioOn: Bool {
        get { defaults.bool(forKey: "systemAudioOn") }
        set { defaults.set(newValue, forKey: "systemAudioOn") }
    }
    private var echoCancellationOn: Bool {
        get { defaults.bool(forKey: "echoCancellation") }
        set { defaults.set(newValue, forKey: "echoCancellation") }
    }
    private var selectedScreen: NSScreen {
        let id = CGDirectDisplayID(defaults.integer(forKey: "displayID"))
        return NSScreen.screens.first { $0.displayID == id }
            ?? NSScreen.screens.first { $0.displayID == CGMainDisplayID() }
            ?? NSScreen.screens[0]
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["cameraOn": true, "micOn": true, "systemAudioOn": true, "echoCancellation": true])

        overlay = CameraOverlay(screen: selectedScreen, deviceID: cameraDeviceID)
        overlay.onHide = { [weak self] in self?.cameraOn = false }
        overlay.onPermissionDenied = { [weak self] in self?.cameraPermissionDenied() }
        if cameraOn { overlay.show() }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        refreshStatusItem()

        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in self?.unexpectedStop(error) }
        }
        hotkey = Hotkey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.toggleRecording()
        }
    }

    // MARK: Status item

    private func refreshStatusItem() {
        if !isRecording { recordingStartedAt = nil }
        guard let button = statusItem.button else { return }
        // Icon only, never text: while recording it just turns red, so it reads as an ordinary icon when screen sharing.
        setIcon(isRecording ? "record.circle.fill" : "record.circle", red: isRecording)
        button.title = ""
        button.imagePosition = .imageOnly
        button.alphaValue = finalizing ? 0.5 : 1
    }

    private func setIcon(_ name: String, red: Bool) {
        guard let button = statusItem.button else { return }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "ScreenRecz")
        if red {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = base?.withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
        } else {
            base?.isTemplate = true
            button.image = base
        }
    }




    // MARK: Recording

    @objc private func toggleRecording() {
        guard !starting, !finalizing else { return }
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            let response = showAlert(
                "Screen recording permission needed",
                "Enable ScreenRecz in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch ScreenRecz.",
                buttons: ["Open System Settings", "Cancel"])
            if response == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        starting = true
        Task {
            defer { starting = false }
            if micOn, await !AVCaptureDevice.requestAccess(for: .audio) {
                micOn = false
                showAlert("Microphone access denied",
                          "Allow ScreenRecz in System Settings > Privacy & Security > Microphone. The microphone has been turned off for now.")
                return
            }
            let options = RecordingOptions(
                displayID: selectedScreen.displayID,
                captureMicrophone: micOn,
                microphoneDeviceID: micDeviceID,
                captureSystemAudio: systemAudioOn,
                echoCancellation: echoCancellationOn,
                overlayWindowID: CGWindowID(overlay.panel.windowNumber))
            do {
                try await recorder.start(options)
                recordingStartedAt = Date()
                refreshStatusItem()
            } catch {
                refreshStatusItem()
                showAlert("Couldn't start recording", error.localizedDescription)
            }
        }
    }

    /// Stops and returns the saved file, if any. Shows "Saving…" while finalizing.
    @discardableResult
    private func finishRecording() async -> URL? {
        finalizing = true
        refreshStatusItem()
        defer {
            finalizing = false
            refreshStatusItem()
        }
        do {
            return try await recorder.stop()
        } catch {
            showAlert("Couldn't save recording", error.localizedDescription)
            return nil
        }
    }

    private func stopRecording() {
        Task {
            if let url = await finishRecording() {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func unexpectedStop(_ error: Error) {
        refreshStatusItem()
        showAlert("Recording stopped", error.localizedDescription)
    }

    private func cameraPermissionDenied() {
        cameraOn = false
        guard !cameraDeniedAlerted else { return }
        cameraDeniedAlerted = true
        showAlert("Camera access denied",
                  "Allow ScreenRecz in System Settings > Privacy & Security > Camera to show the camera overlay.")
    }

    @discardableResult
    private func showAlert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let busy = isRecording || finalizing || starting

        // Elapsed time lives only in the menu, so the status item stays a plain icon.
        elapsedItem = nil
        if isRecording, recordingStartedAt != nil {
            let elapsed = item("", #selector(toggleRecording), enabled: false)
            elapsedItem = elapsed
            updateElapsed()
            menu.addItem(elapsed)
        }
        let toggle = item(isRecording ? "Stop Recording" : "Start Recording", #selector(toggleRecording), enabled: !finalizing)
        toggle.keyEquivalent = "r"
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(toggle)
        menu.addItem(.separator())

        // Display
        let selectedID = selectedScreen.displayID
        let displays = NSMenu()
        for screen in NSScreen.screens {
            displays.addItem(item(screen.localizedName, #selector(pickDisplay(_:)),
                                  on: screen.displayID == selectedID, object: NSNumber(value: screen.displayID)))
        }
        menu.addItem(parent("Display", displays, enabled: !busy))

        // Camera
        menu.addItem(item("Camera", #selector(toggleCamera), on: cameraOn))
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        let activeCamera = cameraDeviceID ?? AVCaptureDevice.default(for: .video)?.uniqueID
        let cameraMenu = deviceMenu(cameras, selected: activeCamera, action: #selector(pickCamera(_:)), empty: "No Cameras")
        menu.addItem(parent("Camera Device", cameraMenu))

        let shapes = NSMenu()
        for s in CameraShape.allCases {
            shapes.addItem(item(s.title, #selector(pickShape(_:)), on: s == overlay.shape, object: s.rawValue))
        }
        menu.addItem(parent("Shape", shapes))
        let sizes = NSMenu()
        for s in CameraSize.allCases {
            sizes.addItem(item(s.title, #selector(pickSize(_:)), on: s == overlay.size, object: s.rawValue))
        }
        menu.addItem(parent("Size", sizes))
        menu.addItem(.separator())

        // Audio
        menu.addItem(item("Microphone", #selector(toggleMic), on: micOn, enabled: !busy))
        let mics = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        let micMenu = NSMenu()
        micMenu.addItem(item("System Default", #selector(pickMic(_:)), on: micDeviceID == nil, object: ""))
        for d in mics {
            micMenu.addItem(item(d.localizedName, #selector(pickMic(_:)), on: d.uniqueID == micDeviceID, object: d.uniqueID))
        }
        menu.addItem(parent("Mic Device", micMenu, enabled: !busy))
        menu.addItem(item("Echo Cancellation", #selector(toggleEchoCancellation), on: echoCancellationOn, enabled: !busy))
        menu.addItem(item("System Audio", #selector(toggleSystemAudio), on: systemAudioOn, enabled: !busy))
        menu.addItem(.separator())

        menu.addItem(item("Open Recordings Folder", #selector(openFolder)))
        menu.addItem(item("Quit", #selector(quit)))
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard elapsedItem != nil else { return }
        // .common so it keeps ticking while the menu is tracking events.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func updateElapsed() {
        guard let elapsedItem, let start = recordingStartedAt else { return }
        let total = max(0, Int(Date().timeIntervalSince(start)))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        let time = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        elapsedItem.attributedTitle = NSAttributedString(string: "Recording  \(time)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false, enabled: Bool = true,
                      object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.isEnabled = enabled
        item.representedObject = object
        return item
    }

    private func parent(_ title: String, _ submenu: NSMenu, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = enabled
        return item
    }

    private func deviceMenu(_ devices: [AVCaptureDevice], selected: String?, action: Selector, empty: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if devices.isEmpty {
            menu.addItem(item(empty, action, enabled: false))
        }
        for d in devices {
            menu.addItem(item(d.localizedName, action, on: d.uniqueID == selected, object: d.uniqueID))
        }
        return menu
    }

    // MARK: Menu actions

    @objc private func pickDisplay(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
              let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        defaults.set(Int(id), forKey: "displayID")
        overlay.move(to: screen)
    }

    @objc private func toggleCamera() {
        cameraOn.toggle()
        if cameraOn {
            cameraDeniedAlerted = false
            overlay.show()
        } else {
            overlay.hide()
        }
    }

    @objc private func pickCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        cameraDeviceID = id
        overlay.setDevice(id: id)
    }

    @objc private func pickShape(_ sender: NSMenuItem) {
        if let s = (sender.representedObject as? String).flatMap(CameraShape.init) { overlay.shape = s }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        if let s = (sender.representedObject as? String).flatMap(CameraSize.init) { overlay.setSize(s) }
    }

    @objc private func toggleMic() { micOn.toggle() }

    @objc private func pickMic(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        micDeviceID = (id?.isEmpty ?? true) ? nil : id
    }

    @objc private func toggleEchoCancellation() { echoCancellationOn.toggle() }

    @objc private func toggleSystemAudio() { systemAudioOn.toggle() }

    @objc private func openFolder() { NSWorkspace.shared.open(RecordingPaths.folder) }

    @objc private func quit() {
        guard isRecording, !finalizing else {
            if !finalizing { NSApp.terminate(nil) }
            return
        }
        Task {
            await finishRecording()
            NSApp.terminate(nil)
        }
    }
}
