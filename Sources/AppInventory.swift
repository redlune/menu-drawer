import AppKit
import ApplicationServices

struct SavedApp: Codable, Identifiable {
    let id: String
    let name: String
    let path: String?

    @MainActor var icon: NSImage {
        if let path, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

struct RunningApp {
    let app: SavedApp
    let pid: pid_t

    static func snapshot(excluding ownBundleID: String) -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { running in
            guard
                let id = running.bundleIdentifier,
                let url = running.bundleURL,
                url.pathExtension == "app",
                id != ownBundleID,
                !id.hasPrefix("com.apple."),
                !running.isTerminated
            else { return nil }

            return RunningApp(
                app: SavedApp(
                    id: id,
                    name: running.localizedName ?? url.deletingPathExtension().lastPathComponent,
                    path: url.path
                ),
                pid: running.processIdentifier
            )
        }
    }
}

enum MenuBarInventory {
    struct Item: Sendable {
        let app: SavedApp
    }

    static func scan(_ candidates: [RunningApp]) async -> Set<String> {
        let scan = Task.detached(priority: .userInitiated) {
            var found: Set<String> = []
            for candidate in candidates {
                if Task.isCancelled { break }
                if !items(for: candidate.pid).isEmpty {
                    found.insert(candidate.app.id)
                }
            }
            return found
        }
        return await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
    }

    static func items(at point: CGPoint, candidates: [RunningApp]) async -> [Item] {
        await withTaskGroup(of: Item?.self) { group in
            var pending = candidates.makeIterator()
            func enqueue(_ candidate: RunningApp) {
                group.addTask {
                    guard !Task.isCancelled,
                          items(for: candidate.pid).contains(where: { itemFrame(of: $0)?.contains(point) == true })
                    else { return nil }
                    return Item(app: candidate.app)
                }
            }
            for _ in 0..<8 {
                if let candidate = pending.next() { enqueue(candidate) }
            }
            var matches: [Item] = []
            while let result = await group.next() {
                if let result { matches.append(result) }
                if !Task.isCancelled, let candidate = pending.next() { enqueue(candidate) }
            }
            return matches
        }
    }

    static func frame(for pid: pid_t) -> CGRect? {
        items(for: pid).compactMap(itemFrame(of:)).first
    }

    static func press(pid: pid_t, menuBarFrames: [CGRect]) async -> Bool {
        let press = Task.detached(priority: .userInitiated) {
            for element in items(for: pid) {
                guard !Task.isCancelled else { return false }
                let targets = actionTargets(in: element)
                guard targets.contains(where: { isInMenuBar(frame(of: $0), menuBarFrames) }) else { continue }
                for target in targets {
                    for action in [kAXPressAction, kAXShowMenuAction] {
                        let result = AXUIElementPerformAction(target, action as CFString)
                        if result == .success || result == .cannotComplete { return true }
                    }
                }
            }
            return false
        }
        return await withTaskCancellationHandler {
            await press.value
        } onCancel: {
            press.cancel()
        }
    }

    static func renderedItemCenter(pid: pid_t, menuBarFrames: [CGRect]) async -> CGPoint? {
        guard let frame = await renderedItemFrame(pid: pid, menuBarFrames: menuBarFrames) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    static func renderedItemFrame(pid: pid_t, menuBarFrames: [CGRect]) async -> CGRect? {
        await Task.detached(priority: .userInitiated) {
            let appItems = items(for: pid).compactMap { item -> (CGRect, Set<String>)? in
                guard let target = actionTargets(in: item).first(where: { isInMenuBar(frame(of: $0), menuBarFrames) }),
                      let frame = frame(of: target) else { return nil }
                return (frame, labels(of: target))
            }
            guard !appItems.isEmpty,
                  let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
            else { return nil }
            let root = accessibilityApp(pid: agent.processIdentifier)
            let windows = value(of: root, kAXWindowsAttribute) as? [AXUIElement] ?? []

            for (appFrame, appLabels) in appItems {
                let candidates = windows.flatMap(children(of:)).filter { slot in
                    guard let slotFrame = frame(of: slot) else { return false }
                    return abs(slotFrame.midX - appFrame.midX) < 2 && abs(slotFrame.midY - appFrame.midY) < 3
                }
                let matches = candidates.filter { slot in
                    children(of: slot).contains { child in
                        guard value(of: child, kAXRoleAttribute) as? String == kAXButtonRole,
                              let frame = frame(of: child) else { return false }
                        let slotLabels = labels(of: child)
                        return abs(frame.midX - appFrame.midX) < 2
                            && abs(frame.midY - appFrame.midY) < 2
                            && abs(frame.width - appFrame.width) < 3
                            && (appLabels.isEmpty || slotLabels.isEmpty || !appLabels.isDisjoint(with: slotLabels))
                    }
                }
                if matches.count == 1, let slot = matches.first, let frame = frame(of: slot) {
                    return frame
                }
            }
            return nil
        }.value
    }

    static func hasOpenMenu(pid: pid_t) async -> Bool {
        await Task.detached {
            items(for: pid).contains { element in
                actionTargets(in: element).contains { target in
                    value(of: target, kAXShownMenuUIElementAttribute) != nil
                        || children(of: target).contains {
                            value(of: $0, kAXRoleAttribute) as? String == kAXMenuRole && frame(of: $0) != nil
                        }
                }
            }
        }.value
    }

    static func leadingItemFrame(in menuBarFrames: [CGRect], containing item: CGRect) async -> CGRect? {
        await Task.detached(priority: .userInitiated) {
            guard let bar = menuBarFrames.first(where: { $0.contains(CGPoint(x: item.midX, y: item.midY)) }),
                  let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
            else { return nil }
            let root = accessibilityApp(pid: agent.processIdentifier)
            let windows = value(of: root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let frames = windows.flatMap(children(of:)).compactMap { slot -> CGRect? in
                guard let rect = frame(of: slot), rect.height > 0, rect.height <= bar.height,
                      bar.contains(CGPoint(x: rect.midX, y: rect.midY)),
                      abs(rect.midY - item.midY) < 3,
                      children(of: slot).contains(where: { value(of: $0, kAXRoleAttribute) as? String == kAXButtonRole })
                else { return nil }
                return rect
            }
            return frames.min(by: { $0.minX < $1.minX })
        }.value
    }

    static func popupFrames(pid: pid_t) async -> Set<CGRect> {
        await Task.detached {
            let app = accessibilityApp(pid: pid)
            var windows = value(of: app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let focused = value(of: app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                windows.append(focused as! AXUIElement)
            }
            return Set(windows.compactMap { window in
                guard value(of: window, kAXMinimizedAttribute) as? Bool != true,
                      let frame = frame(of: window), frame.width >= 35, frame.height >= 32 else { return nil }
                return frame
            })
        }.value
    }

    private static func accessibilityApp(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        return app
    }

    private static func items(for pid: pid_t) -> [AXUIElement] {
        let app = accessibilityApp(pid: pid)
        guard let extras = value(of: app, "AXExtrasMenuBar"),
              CFGetTypeID(extras) == AXUIElementGetTypeID() else { return [] }
        return children(of: extras as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        value(of: element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func actionTargets(in element: AXUIElement) -> [AXUIElement] {
        let buttons = children(of: element).filter {
            let role = value(of: $0, kAXRoleAttribute) as? String
            return role == kAXButtonRole || role == kAXMenuBarItemRole
        }
        return buttons + [element]
    }

    private static func itemFrame(of element: AXUIElement) -> CGRect? {
        actionTargets(in: element).compactMap(frame(of:)).first
    }

    private static func labels(of element: AXUIElement) -> Set<String> {
        Set([kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute in
            guard let label = value(of: element, attribute) as? String,
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return label
        })
    }

    private static func isInMenuBar(_ frame: CGRect?, _ menuBarFrames: [CGRect]) -> Bool {
        guard let frame else { return false }
        return menuBarFrames.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(of: element, kAXPositionAttribute),
              let size = value(of: element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite,
              dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}
