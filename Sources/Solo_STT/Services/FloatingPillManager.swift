import AppKit
import SwiftUI

// Custom view that handles dragging without triggering macOS window tiling
private class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var dragOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOrigin else { return }
        let current = event.locationInWindow
        let dx = current.x - dragOrigin.x
        let dy = current.y - dragOrigin.y
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        // Notify that drag ended so position can be saved
        NotificationCenter.default.post(name: .pillDragEnded, object: window)
    }
}

extension Notification.Name {
    static let pillDragEnded = Notification.Name("pillDragEnded")
}

class FloatingPillManager {
    private var panel: NSPanel?
    private var appState: AppState
    private var observationTimer: Timer?
    private var isVisible = false
    private var lastState: String = "idle"

    // Offset from screen: dx from center, dy from bottom
    private static let offsetDXKey = "pillOffsetDX"
    private static let offsetDYKey = "pillOffsetDY"

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(onDragEnded),
            name: .pillDragEnded, object: nil
        )
        observationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        observationTimer?.invalidate()
        observationTimer = nil
        hidePanel()
    }

    // MARK: - State Observation

    private func tick() {
        let stateKey: String
        switch appState.recordingState {
        case .recording: stateKey = "recording"
        case .transcribing: stateKey = "transcribing"
        case .idle: stateKey = "idle"
        case .error: stateKey = "error"
        }

        if stateKey == "recording" || stateKey == "transcribing" {
            if !isVisible {
                showPanel()
            } else if stateKey != lastState {
                updateContent()
            }
        } else {
            if isVisible {
                hidePanel()
            }
        }
        lastState = stateKey
    }

    // MARK: - Panel

    private func createPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        return panel
    }

    private func setContent(on panel: NSPanel) {
        let view = FloatingPillView(recordingState: appState.recordingState)
        let hostingView = DraggableHostingView(rootView: view)
        hostingView.frame.size = hostingView.fittingSize
        panel.setContentSize(hostingView.fittingSize)
        panel.contentView = hostingView
    }

    /// Screen where the frontmost app lives (fallback to main)
    private func activeScreen() -> NSScreen {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let pid = Optional(frontApp.processIdentifier),
           let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in windowInfo {
                guard let windowPID = info[kCGWindowOwnerPID as String] as? Int32,
                      windowPID == pid,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                      let wx = bounds["X"], let wy = bounds["Y"] else { continue }
                let point = NSPoint(x: wx, y: wy)
                for screen in NSScreen.screens {
                    if screen.frame.contains(point) { return screen }
                }
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func positionPanel(_ panel: NSPanel) {
        let screen = activeScreen()
        let panelSize = panel.frame.size
        let defaults = UserDefaults.standard

        let dx: CGFloat
        let dy: CGFloat
        if defaults.object(forKey: Self.offsetDXKey) != nil {
            dx = defaults.double(forKey: Self.offsetDXKey)
            dy = defaults.double(forKey: Self.offsetDYKey)
        } else {
            dx = 0
            dy = 80
        }

        let x = screen.frame.midX - panelSize.width / 2 + dx
        let y = screen.frame.minY + dy
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func savePosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let origin = panel.frame.origin
        let panelSize = panel.frame.size
        let dx = origin.x - (screen.frame.midX - panelSize.width / 2)
        let dy = origin.y - screen.frame.minY
        UserDefaults.standard.set(dx, forKey: Self.offsetDXKey)
        UserDefaults.standard.set(dy, forKey: Self.offsetDYKey)
    }

    // MARK: - Show / Hide

    private func showPanel() {
        let p = createPanel()
        setContent(on: p)
        positionPanel(p)
        panel = p

        // Animate in
        p.alphaValue = 0
        let finalOrigin = p.frame.origin
        p.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y - 10))
        p.orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrameOrigin(finalOrigin)
        }

        isVisible = true
    }

    private func hidePanel() {
        guard let p = panel else { return }

        savePosition()
        let origin = p.frame.origin

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            p.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 10))
        }, completionHandler: { [weak self] in
            p.orderOut(nil)
            self?.panel = nil
        })

        isVisible = false
    }

    private func updateContent() {
        guard let p = panel else { return }
        setContent(on: p)
    }

    @objc private func onDragEnded(_ notification: Notification) {
        savePosition()
    }

    deinit {
        observationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
