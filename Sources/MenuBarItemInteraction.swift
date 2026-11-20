import CoreGraphics

@MainActor
enum MenuBarItemInteraction {
    enum OpenMenu {
        case accessibility
        case popup(MenuBarInventory.WindowID)
    }

    static func openMenu(
        pid: pid_t, menuBarFrames: [CGRect], originalWindows: Set<MenuBarInventory.WindowID>
    ) async -> OpenMenu? {
        let anchor = await MenuBarInventory.renderedItemFrame(pid: pid, menuBarFrames: menuBarFrames)
        guard !Task.isCancelled else { return nil }
        if await MenuBarInventory.press(pid: pid, menuBarFrames: menuBarFrames),
           let menu = await waitForMenu(pid: pid, anchor: anchor, originalWindows: originalWindows,
                                        timeout: .milliseconds(450)) {
            return menu
        }
        guard !Task.isCancelled else { return nil }
        if let menu = await visibleMenu(pid: pid, anchor: anchor, originalWindows: originalWindows) { return menu }
        guard !Task.isCancelled,
              let frame = await MenuBarInventory.renderedItemFrame(pid: pid, menuBarFrames: menuBarFrames),
              !Task.isCancelled,
              await MenuBarClick.send(to: CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        return await waitForMenu(pid: pid, anchor: frame, originalWindows: originalWindows, timeout: .seconds(1))
    }

    static func moveToLeadingEdge(pid: pid_t, menuBarFrames: [CGRect], isCurrent: () -> Bool) async -> Bool {
        // A newly launched app can appear in NSWorkspace before its status item exists.
        for delay: Duration in [.zero, .milliseconds(400), .seconds(1)] {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, isCurrent() else { return false }
            if let result = await tryLeadingPlacement(pid: pid, menuBarFrames: menuBarFrames, isCurrent: isCurrent) {
                return result
            }
        }
        return false
    }

    private static func tryLeadingPlacement(pid: pid_t, menuBarFrames: [CGRect], isCurrent: () -> Bool) async -> Bool? {
        guard let frame = await MenuBarInventory.renderedItemFrame(pid: pid, menuBarFrames: menuBarFrames),
              let leading = await MenuBarInventory.leadingItemFrame(in: menuBarFrames, containing: frame)
        else { return nil }
        guard !Task.isCancelled, isCurrent() else { return false }
        if frame.minX <= leading.minX + 1 { return true }
        guard await MenuBarInventory.renderedItemFrame(pid: pid, menuBarFrames: menuBarFrames) == frame else { return nil }
        guard !Task.isCancelled, isCurrent() else { return false }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let end = CGPoint(x: leading.minX + 1, y: frame.midY)
        guard await MenuBarClick.move(from: start, to: end) else { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !Task.isCancelled, isCurrent() {
            if let current = await MenuBarInventory.renderedItemFrame(pid: pid, menuBarFrames: menuBarFrames),
               let first = await MenuBarInventory.leadingItemFrame(in: menuBarFrames, containing: current),
               current.minX <= first.minX + 1 {
                return true
            }
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    static func menuIsOpen(pid: pid_t, menu: OpenMenu) async -> Bool {
        switch menu {
        case .accessibility:
            await MenuBarInventory.hasOpenMenu(pid: pid)
        case .popup(let id):
            await MenuBarInventory.popupIsOpen(pid: pid, id: id)
        }
    }

    private static func visibleMenu(
        pid: pid_t, anchor: CGRect?, originalWindows: Set<MenuBarInventory.WindowID>
    ) async -> OpenMenu? {
        if let anchor, let popup = await MenuBarInventory.newPopup(pid: pid, near: anchor, excluding: originalWindows) {
            return .popup(popup)
        }
        if await MenuBarInventory.hasOpenMenu(pid: pid) { return .accessibility }
        return nil
    }

    private static func waitForMenu(
        pid: pid_t, anchor: CGRect?, originalWindows: Set<MenuBarInventory.WindowID>, timeout: Duration
    ) async -> OpenMenu? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !Task.isCancelled {
            if let menu = await visibleMenu(pid: pid, anchor: anchor, originalWindows: originalWindows) { return menu }
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(75))
        }
        return nil
    }
}
