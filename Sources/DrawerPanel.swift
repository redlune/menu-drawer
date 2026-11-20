import AppKit

final class DrawerPanel: NSPanel {
    private let onDismiss: () -> Void
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var presentedAt: TimeInterval = 0
    private var dismissesOnResignKey = false

    init(content: NSViewController, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        contentViewController = content
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }

    override func resignKey() {
        super.resignKey()
        if dismissesOnResignKey { onDismiss() }
    }

    func present(anchor: CGRect?, appCount: Int, dismissesOnResignKey: Bool) {
        guard let primary = NSScreen.screens.first else { return }
        self.dismissesOnResignKey = dismissesOnResignKey
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? primary
        let anchorY = anchor.map { primary.frame.maxY - $0.maxY } ?? screen.visibleFrame.maxY
        let menuIsHere = abs(screen.frame.maxY - pointer.y) < 70
        let anchorOnScreen = abs(screen.frame.maxY - anchorY) < 70
            && anchor.map { $0.midX >= screen.frame.minX && $0.midX <= screen.frame.maxX } == true
        let fallbackX = menuIsHere ? pointer.x : screen.visibleFrame.maxX - 80
        let centerX = anchorOnScreen ? anchor?.midX ?? pointer.x : fallbackX
        let contentWidth = appCount == 0 ? 245 : CGFloat(appCount) * 34 + 58
        let width = min(contentWidth, min(480, screen.visibleFrame.width - 16))
        let height: CGFloat = 46
        let x = min(max(centerX - width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
        let y = min(screen.visibleFrame.maxY, anchorOnScreen ? anchorY : screen.frame.maxY - NSStatusBar.system.thickness)
        setFrame(NSRect(x: x, y: y - height - 6, width: width, height: height), display: false)
        presentedAt = ProcessInfo.processInfo.systemUptime
        makeKeyAndOrderFront(nil)
        monitorClicks()
    }

    func hide() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        dismissesOnResignKey = false
        orderOut(nil)
    }

    private func monitorClicks() {
        guard localClickMonitor == nil, globalClickMonitor == nil else { return }
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissIfOutside(event) }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissIfOutside(event) }
        }
    }

    private func dismissIfOutside(_ event: NSEvent) {
        guard isVisible, event.window !== self, event.timestamp >= presentedAt else { return }
        let point: CGPoint
        if let mouseEvent = event.cgEvent, let primary = NSScreen.screens.first {
            // Quartz events use a global top-left origin. Window frames use AppKit coordinates.
            guard mouseEvent.getIntegerValueField(.eventSourceUserData) != MenuBarClick.eventMarker else { return }
            point = CGPoint(x: mouseEvent.location.x, y: primary.frame.maxY - mouseEvent.location.y)
        } else {
            point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        }
        if !frame.contains(point) { onDismiss() }
    }
}
