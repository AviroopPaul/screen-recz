@preconcurrency import AVFoundation
import AppKit

enum CameraShape: String, CaseIterable {
    case circle, rounded, square, wide

    var title: String {
        switch self {
        case .circle: return "Circle"
        case .rounded: return "Rounded"
        case .square: return "Square"
        case .wide: return "Wide"
        }
    }

    var aspect: CGFloat { self == .wide ? 16.0 / 9.0 : 1 }

    func cornerRadius(for size: CGSize) -> CGFloat {
        switch self {
        case .circle: return min(size.width, size.height) / 2
        case .rounded: return 0.16 * min(size.width, size.height)
        case .square: return 0
        case .wide: return 0.08 * size.height
        }
    }
}

enum CameraSize: String, CaseIterable {
    case small, medium, large

    var title: String { rawValue.capitalized }

    var height: CGFloat {
        switch self {
        case .small: return 140
        case .medium: return 220
        case .large: return 340
        }
    }
}

/// Never takes focus; only exists to host the camera preview and receive scroll/pinch/right-click.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var shape: CameraShape = .circle { didSet { needsLayout = true } }
    var onScroll: ((NSEvent) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        layer?.cornerRadius = shape.cornerRadius(for: bounds.size)
        CATransaction.commit()
        window?.invalidateShadow()
    }

    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func magnify(with event: NSEvent) { onMagnify?(event.magnification) }
}

@MainActor
final class CameraOverlay: NSObject, NSMenuDelegate {
    static let heightRange: ClosedRange<CGFloat> = 100...600

    let panel: OverlayPanel
    /// Called when the user picks "Hide Camera" from the overlay's context menu.
    var onHide: (() -> Void)?
    /// Called when camera access is denied, after the overlay has hidden itself.
    var onPermissionDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "screenrecz.camera")
    private let view: OverlayView
    private let defaults = UserDefaults.standard
    private var screen: NSScreen
    private var deviceID: String?
    private(set) var isVisible = false
    private var moveObserver: NSObjectProtocol?

    private(set) var height: CGFloat
    var shape: CameraShape {
        didSet {
            defaults.set(shape.rawValue, forKey: "cameraShape")
            view.shape = shape
            resize(animated: true)
        }
    }
    var size: CameraSize? { CameraSize.allCases.first { $0.height == height } }

    init(screen: NSScreen, deviceID: String?) {
        self.screen = screen
        self.deviceID = deviceID
        let d = UserDefaults.standard
        shape = d.string(forKey: "cameraShape").flatMap(CameraShape.init) ?? .circle
        let saved = CGFloat(d.double(forKey: "cameraHeight"))
        height = Self.heightRange.contains(saved) ? saved : CameraSize.medium.height
        view = OverlayView(session: session)
        view.shape = shape

        panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = view

        view.onScroll = { [weak self] event in
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 6
            self?.setHeight((self?.height ?? 0) + event.scrollingDeltaY * step)
        }
        view.onMagnify = { [weak self] m in
            guard let self else { return }
            setHeight(height * (1 + m))
        }
        let menu = NSMenu()
        menu.delegate = self
        view.menu = menu

        panel.setFrame(initialFrame(), display: false)
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.defaults.set(self.panel.frame.origin.x, forKey: "overlayX")
                self.defaults.set(self.panel.frame.origin.y, forKey: "overlayY")
            }
        }
    }

    // MARK: Public API

    func show() {
        guard !isVisible else { return }
        isVisible = true
        withCameraAccess { [weak self] in
            guard let self, isVisible else { return }
            panel.orderFrontRegardless()
            startSession()
        }
    }

    func hide() {
        isVisible = false
        panel.orderOut(nil)
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func setDevice(id: String?) {
        deviceID = id
        let running = isVisible
        queue.async { [session] in
            if running {
                Self.configure(session, deviceID: id)
            } else {
                // Reconfigured lazily on the next show().
                session.inputs.forEach { session.removeInput($0) }
            }
        }
        if running { applyMirroringSoon() }
    }

    func setSize(_ size: CameraSize) {
        setHeight(size.height, animated: true)
    }

    func setHeight(_ value: CGFloat, animated: Bool = false) {
        height = min(max(value, Self.heightRange.lowerBound), Self.heightRange.upperBound)
        defaults.set(Double(height), forKey: "cameraHeight")
        resize(animated: animated)
    }

    /// Moves to another display, keeping the relative position inside its visible frame.
    func move(to newScreen: NSScreen) {
        let old = currentScreen.visibleFrame
        let f = panel.frame
        let fx = (old.width - f.width) > 1 ? (f.minX - old.minX) / (old.width - f.width) : 0
        let fy = (old.height - f.height) > 1 ? (f.minY - old.minY) / (old.height - f.height) : 0
        screen = newScreen
        let vf = newScreen.visibleFrame
        let frame = fitted(height: height, origin: NSPoint(x: vf.minX + fx * (vf.width - f.width),
                                                           y: vf.minY + fy * (vf.height - f.height)), on: newScreen)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: Geometry

    private var currentScreen: NSScreen { panel.screen ?? screen }

    private func size(forHeight h: CGFloat, on screen: NSScreen) -> NSSize {
        let vf = screen.visibleFrame
        let h = min(h, vf.height, vf.width / shape.aspect)
        return NSSize(width: h * shape.aspect, height: h)
    }

    private func fitted(height h: CGFloat, origin: NSPoint, on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let s = size(forHeight: h, on: screen)
        return NSRect(x: min(max(origin.x, vf.minX), vf.maxX - s.width),
                      y: min(max(origin.y, vf.minY), vf.maxY - s.height), width: s.width, height: s.height)
    }

    private func initialFrame() -> NSRect {
        let vf = screen.visibleFrame
        if defaults.object(forKey: "overlayX") != nil {
            let origin = NSPoint(x: defaults.double(forKey: "overlayX"), y: defaults.double(forKey: "overlayY"))
            let frame = fitted(height: height, origin: origin, on: screen)
            if vf.contains(frame) && frame.origin == origin { return frame }
        }
        return fitted(height: height, origin: NSPoint(x: vf.minX + 40, y: vf.minY + 40), on: screen)
    }

    /// Resizes around the current center, then nudges back on-screen.
    private func resize(animated: Bool) {
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let s = size(forHeight: height, on: currentScreen)
        let frame = fitted(height: height, origin: NSPoint(x: c.x - s.width / 2, y: c.y - s.height / 2), on: currentScreen)
        guard frame != panel.frame else { return }
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    // MARK: Camera session

    private func withCameraAccess(_ body: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            body()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in granted ? body() : self?.denied() }
            }
        default:
            denied()
        }
    }

    private func denied() {
        isVisible = false
        panel.orderOut(nil)
        onPermissionDenied?()
    }

    private func startSession() {
        let id = deviceID
        queue.async { [session, weak self] in
            if session.inputs.isEmpty { Self.configure(session, deviceID: id) }
            if !session.isRunning { session.startRunning() }
            Task { @MainActor in self?.applyMirroring() }
        }
    }

    nonisolated private static func configure(_ session: AVCaptureSession, deviceID: String?) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
        if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        session.commitConfiguration()
    }

    private func applyMirroringSoon() {
        queue.async { [weak self] in
            Task { @MainActor in self?.applyMirroring() }
        }
    }

    private func applyMirroring() {
        guard let c = view.previewLayer.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = true
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shapes = NSMenu()
        for s in CameraShape.allCases {
            let item = NSMenuItem(title: s.title, action: #selector(pickShape(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = s == shape ? .on : .off
            shapes.addItem(item)
        }
        let sizes = NSMenu()
        for s in CameraSize.allCases {
            let item = NSMenuItem(title: s.title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = s == size ? .on : .off
            sizes.addItem(item)
        }
        for (title, sub) in [("Shape", shapes), ("Size", sizes)] {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Camera", action: #selector(hideFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
    }

    @objc private func pickShape(_ sender: NSMenuItem) {
        if let s = (sender.representedObject as? String).flatMap(CameraShape.init) { shape = s }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        if let s = (sender.representedObject as? String).flatMap(CameraSize.init) { setSize(s) }
    }

    @objc private func hideFromMenu() {
        hide()
        onHide?()
    }
}
