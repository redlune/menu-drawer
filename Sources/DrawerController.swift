import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class DrawerController: NSObject, NSApplicationDelegate, @preconcurrency NSStatusItemExpandedInterfaceDelegate, ObservableObject {
    @Published private(set) var hiddenApps: [SavedApp] = []
    @Published private(set) var runningApps: [RunningApp] = []
    @Published private(set) var menuBarAppIDs: Set<String> = []
    @Published private(set) var hasAccessibility = false
    @Published private(set) var isScanning = false
    @Published private(set) var isCollapsed = false
    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var menuOpenError: String?
    @Published private(set) var preparingAppIDs: Set<String> = []
    @Published var search = ""
    @Published var showAllRunning = false
    @Published var hoveringDrawer = false
    @Published var hoveringMenuBar = false
    @Published var autoCollapseDelay = 0 {
        didSet {
            defaults.set(autoCollapseDelay, forKey: "AutoCollapseDelay")
            scheduleAutoCollapse()
        }
    }

    private let defaults = UserDefaults.standard
    private let bundleID = Bundle.main.bundleIdentifier ?? "local.yubi.MenuDrawer"
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var drawerPanel: DrawerPanel?
    private var drawerLocalClickMonitor: Any?
    private var drawerGlobalClickMonitor: Any?
    private var drawerPresentedAt: TimeInterval = 0
    private let dragMonitor = MenuBarDragMonitor()
    private var accessTimer: Timer?
    private var interactionTask: Task<Void, Never>?
    private var openingAppID: String?
    private var placementQueue: [SavedApp] = []
    private var placementTask: Task<Void, Never>?
    private var placementGeneration = UUID()
    private var placements: [String: (pid: pid_t, ready: Bool)] = [:]
    private var lastLayoutScanPIDs: Set<pid_t> = []
    private var runningObservation: NSKeyValueObservation?
    private var scanTask: Task<Void, Never>?
    private var autoCollapseTimer: Timer?
    private var wantsCollapsed = false
    private var activeToken: NSObject?
    private var activeBundles: Set<String>?
    private var pendingToken: NSObject?
    private var pendingBundles: Set<String>?
    private var pendingRequest: UUID?
    private var requestTimeout: DispatchWorkItem?

    var installationRequired: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return !path.hasPrefix("/Applications/")
    }

    var canHide: Bool {
        !installationRequired && VisibilityBridge.isAvailable()
    }

    var drawerApps: [SavedApp] {
        let running = Set(runningApps.map { $0.app.id })
        return hiddenApps.filter { running.contains($0.id) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = defaults.data(forKey: "HiddenApps"),
           let saved = try? JSONDecoder().decode([SavedApp].self, from: data) {
            hiddenApps = saved.filter { $0.id != bundleID && !$0.id.hasPrefix("com.apple.") }
        }
        let delay = defaults.integer(forKey: "AutoCollapseDelay")
        autoCollapseDelay = [0, 10, 30, 60].contains(delay) ? delay : 0

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "MenuDrawer"
        item.isVisible = true
        item.expandedInterfaceDelegate = self
        statusItem = item
        updateStatusItem()

        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshRunningApps()
                if self.settingsWindow?.isVisible == true,
                   self.lastLayoutScanPIDs != Set(self.runningApps.map(\.pid)) {
                    self.refreshMenuBarApps()
                }
            }
        }
        refreshRunningApps()
        updateAccessibility()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateAccessibility() }
        }
        if !defaults.bool(forKey: "SawLayoutEditor") || installationRequired {
            showSettings()
        }
        if !hiddenApps.isEmpty && canHide { collapse() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDrawer()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dismissDrawer()
        accessTimer?.invalidate()
        dragMonitor.stop()
        cancelPlacement()
        restore()
    }

    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        if NSEvent.modifierFlags.contains(.option) {
            session.cancel()
            showSettings()
            return
        }
        showDrawer()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        hideDrawerPanel()
    }

    func dismissDrawer() {
        hideDrawerPanel()
        statusItem?.expandedInterfaceSession?.cancel()
    }

    private func hideDrawerPanel() {
        if let drawerLocalClickMonitor {
            NSEvent.removeMonitor(drawerLocalClickMonitor)
            self.drawerLocalClickMonitor = nil
        }
        if let drawerGlobalClickMonitor {
            NSEvent.removeMonitor(drawerGlobalClickMonitor)
            self.drawerGlobalClickMonitor = nil
        }
        drawerPanel?.dismissesOnResignKey = false
        drawerPanel?.orderOut(nil)
    }

    private func monitorDrawerClicks() {
        guard drawerLocalClickMonitor == nil, drawerGlobalClickMonitor == nil else { return }
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        drawerLocalClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissDrawerIfOutside(event) }
            return event
        }
        drawerGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissDrawerIfOutside(event) }
        }
    }

    private func dismissDrawerIfOutside(_ event: NSEvent) {
        guard let panel = drawerPanel, panel.isVisible, event.window !== panel,
              event.timestamp >= drawerPresentedAt else { return }
        let point: CGPoint
        if let mouseEvent = event.cgEvent, let primary = NSScreen.screens.first {
            // Quartz events use a global top-left origin. Window frames use AppKit coordinates.
            guard mouseEvent.getIntegerValueField(.eventSourceUserData) != MenuBarClick.eventMarker else { return }
            point = CGPoint(x: mouseEvent.location.x, y: primary.frame.maxY - mouseEvent.location.y)
        } else {
            point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        }
        if !panel.frame.contains(point) { dismissDrawer() }
    }

    func toggle() {
        if wantsCollapsed {
            expand()
        } else {
            collapse()
        }
    }

    func setHidden(_ app: SavedApp, to shouldHide: Bool) {
        guard app.id != bundleID, !app.id.hasPrefix("com.apple.") else { return }
        if shouldHide {
            if !hiddenApps.contains(where: { $0.id == app.id }) { hiddenApps.append(app) }
            placements.removeValue(forKey: app.id)
        } else {
            hiddenApps.removeAll { $0.id == app.id }
            menuBarAppIDs.insert(app.id)
            placementQueue.removeAll { $0.id == app.id }
            preparingAppIDs.remove(app.id)
            placements.removeValue(forKey: app.id)
        }
        prepareHiddenApps()
        if let data = try? JSONEncoder().encode(hiddenApps) {
            defaults.set(data, forKey: "HiddenApps")
        }
        if hiddenApps.isEmpty {
            restore()
        } else if shouldHide && canHide {
            collapse()
        } else {
            if openingAppID == app.id { endInteraction() }
            syncVisibility()
        }
        updateStatusItem()
    }

    func moveApp(id: String, toDrawer: Bool) {
        let app = toDrawer
            ? runningApps.first(where: { $0.app.id == id })?.app
            : hiddenApps.first(where: { $0.id == id })
        if let app { setHidden(app, to: toDrawer) }
    }

    func refreshMenuBarApps() {
        refreshRunningApps()
        lastLayoutScanPIDs = Set(runningApps.map(\.pid))
        scanTask?.cancel()
        updateAccessibility(refresh: false)
        guard hasAccessibility else {
            menuBarAppIDs = []
            isScanning = false
            return
        }

        isScanning = true
        let candidates = runningApps
        scanTask = Task { [weak self] in
            let ids = await MenuBarInventory.scan(candidates)
            guard !Task.isCancelled, let self else { return }
            menuBarAppIDs = ids
            isScanning = false
        }
    }

    func requestAccessibility() {
        if !AXIsProcessTrusted(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshMenuBarApps()
    }

    private func refreshRunningApps() {
        runningApps = RunningApp.snapshot(excluding: bundleID)
        let pids = Dictionary(runningApps.map { ($0.app.id, $0.pid) }, uniquingKeysWith: { first, _ in first })
        placements = placements.filter { pids[$0.key] == $0.value.pid }
        prepareHiddenApps()
        syncVisibility()
    }

    private func collapse() {
        guard !hiddenApps.isEmpty else { return }
        guard canHide else {
            errorMessage = installationRequired
                ? String(localized: "error.installationRequired")
                : String(localized: "error.unsupportedOS")
            showSettings()
            return
        }
        errorMessage = nil
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
        wantsCollapsed = true
        syncVisibility()
    }

    private func expand() {
        restore()
        errorMessage = nil
        scheduleAutoCollapse()
    }

    private func syncVisibility() {
        guard wantsCollapsed else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var hidden = Set(hiddenApps.map(\.id))
        hidden.subtract(preparingAppIDs)
        if let openingAppID { hidden.remove(openingAppID) }
        guard !running.isDisjoint(with: hidden) else {
            clearRestriction()
            isCollapsed = true
            updateStatusItem()
            return
        }

        applyVisibility(allowing: running.subtracting(hidden).union([bundleID]))
    }

    private func applyVisibility(allowing allowed: Set<String>) {
        guard allowed != pendingBundles else { return }
        cancelPendingRequest()
        guard allowed != activeBundles else {
            updateStatusItem()
            return
        }

        let request = UUID()
        pendingRequest = request
        pendingBundles = allowed
        isApplying = true
        pendingToken = VisibilityBridge.restrict(toBundles: allowed.sorted()) { [weak self] error in
            self?.finishRequest(request, error: error)
        }
        guard pendingToken != nil else {
            failToHide()
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard self?.pendingRequest == request else { return }
            self?.failToHide()
        }
        requestTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
        updateStatusItem()
    }

    private func finishRequest(_ request: UUID, error: Error?) {
        guard pendingRequest == request else { return }
        if let error {
            NSLog("Menu bar visibility request failed: %@", error.localizedDescription)
            failToHide()
            return
        }
        guard let token = pendingToken else {
            failToHide()
            return
        }
        if let activeToken {
            VisibilityBridge.restore(activeToken)
        }
        activeToken = token
        activeBundles = pendingBundles
        pendingToken = nil
        cancelPendingRequest()
        isCollapsed = true
        updateStatusItem()
    }

    private func failToHide() {
        restore()
        errorMessage = String(localized: "error.hideFailed")
        showSettings()
    }

    private func restore() {
        endInteraction()
        wantsCollapsed = false
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
        clearRestriction()
        updateStatusItem()
    }

    private func clearRestriction() {
        cancelPendingRequest()
        if let activeToken {
            VisibilityBridge.restore(activeToken)
        }
        activeToken = nil
        activeBundles = nil
        isCollapsed = false
    }

    private func cancelPendingRequest() {
        requestTimeout?.cancel()
        requestTimeout = nil
        pendingRequest = nil
        pendingBundles = nil
        if let pendingToken {
            VisibilityBridge.restore(pendingToken)
        }
        pendingToken = nil
        isApplying = false
    }

    private func scheduleAutoCollapse() {
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
        guard autoCollapseDelay > 0, !hiddenApps.isEmpty, !wantsCollapsed, canHide else { return }
        autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(autoCollapseDelay), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.autoCollapseIfIdle() }
        }
    }

    private func autoCollapseIfIdle() {
        let pointer = NSEvent.mouseLocation
        let interactingWithMenuBar = NSScreen.screens.contains { screen in
            screen.frame.contains(pointer) && pointer.y >= screen.frame.maxY - max(36, NSStatusBar.system.thickness)
        }
        if interactingWithMenuBar || settingsWindow?.isKeyWindow == true || drawerPanel?.isVisible == true
            || openingAppID != nil {
            scheduleAutoCollapse()
        } else {
            collapse()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol = isCollapsed ? "tray.fill" : "tray"
        let title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.image?.isTemplate = true
        button.toolTip = String(localized: "statusItem.help")
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(button.toolTip)
    }

    private func updateAccessibility(refresh: Bool = true) {
        let trusted = AXIsProcessTrusted()
        guard trusted != hasAccessibility else { return }
        hasAccessibility = trusted
        if trusted {
            prepareHiddenApps()
            dragMonitor.start(
                candidates: { [weak self] in
                    guard let self else { return [] }
                    let hidden = self.isCollapsed ? Set(self.hiddenApps.map(\.id)) : []
                    return self.runningApps.filter { !hidden.contains($0.app.id) }
                },
                anchor: { [weak self] in self?.menuBarAnchor() },
                didDrop: { [weak self] app in self?.setHidden(app, to: true) }
            )
        } else {
            cancelPlacement()
            dragMonitor.stop()
            if openingAppID != nil {
                endInteraction()
            }
            syncVisibility()
        }
        if refresh, settingsWindow?.isVisible == true { refreshMenuBarApps() }
    }

    private var menuBarFrames: [CGRect] {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let height = max(38, NSStatusBar.system.thickness + 8)
        return NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: primaryTop - $0.frame.maxY, width: $0.frame.width, height: height)
        }
    }

    private func prepareHiddenApps() {
        guard hasAccessibility, canHide else { return }
        for app in hiddenApps {
            guard let running = runningApps.first(where: { $0.app.id == app.id }),
                  placements[app.id]?.pid != running.pid,
                  preparingAppIDs.insert(app.id).inserted else { continue }
            placementQueue.append(app)
        }
        guard placementTask == nil, !placementQueue.isEmpty else { return }
        let generation = UUID()
        placementGeneration = generation
        placementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !placementQueue.isEmpty {
                let app = placementQueue.removeFirst()
                // Finish intake before a menu can open. Never drag while another menu is in use.
                while !Task.isCancelled, openingAppID != nil
                    || CGEventSource.buttonState(.combinedSessionState, button: .left) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled else { break }
                guard hiddenApps.contains(where: { $0.id == app.id }),
                      let running = runningApps.first(where: { $0.app.id == app.id }) else {
                    preparingAppIDs.remove(app.id)
                    syncVisibility()
                    continue
                }
                syncVisibility()
                await waitForMenuBarLayout()
                guard !Task.isCancelled else { break }
                let ready = await placeAtLeadingEdge(pid: running.pid, menuBarFrames: menuBarFrames)
                guard !Task.isCancelled else { break }
                if hiddenApps.contains(where: { $0.id == app.id }),
                   runningApps.contains(where: { $0.app.id == app.id && $0.pid == running.pid }) {
                    placements[app.id] = (running.pid, ready)
                }
                preparingAppIDs.remove(app.id)
                syncVisibility()
            }
            guard placementGeneration == generation else { return }
            placementTask = nil
            prepareHiddenApps()
        }
    }

    private func cancelPlacement() {
        placementGeneration = UUID()
        placementTask?.cancel()
        placementTask = nil
        placementQueue = []
        preparingAppIDs = []
    }

    private func menuBarAnchor() -> CGRect? {
        if let button = statusItem?.button, let window = button.window, let primary = NSScreen.screens.first {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            if NSScreen.screens.contains(where: { abs($0.frame.maxY - frame.maxY) < 48 && $0.frame.intersects(frame) }) {
                return CGRect(
                    x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height
                )
            }
        }
        guard hasAccessibility else { return nil }
        return MenuBarInventory.frame(for: ProcessInfo.processInfo.processIdentifier)
    }

    func showDrawer() {
        settingsWindow?.orderOut(nil)
        menuOpenError = nil
        presentDrawer()
    }

    private func presentDrawer() {
        updateAccessibility()
        if openingAppID != nil {
            endInteraction()
            syncVisibility()
        }
        if drawerPanel == nil {
            let panel = DrawerPanel(
                contentRect: NSRect(x: 0, y: 0, width: 160, height: 46),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .popUpMenu
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: DrawerView(controller: self))
            panel.onCancel = { [weak self] in self?.dismissDrawer() }
            drawerPanel = panel
        }
        guard let panel = drawerPanel, let primary = NSScreen.screens.first else { return }
        panel.dismissesOnResignKey = statusItem?.expandedInterfaceSession == nil
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? primary
        let anchor = menuBarAnchor()
        let anchorY = anchor.map { primary.frame.maxY - $0.maxY } ?? screen.visibleFrame.maxY
        let menuIsHere = abs(screen.frame.maxY - pointer.y) < 70
        let anchorOnScreen = abs(screen.frame.maxY - anchorY) < 70
            && anchor.map { $0.midX >= screen.frame.minX && $0.midX <= screen.frame.maxX } == true
        let centerX = anchorOnScreen ? anchor?.midX ?? pointer.x : (menuIsHere ? pointer.x : screen.visibleFrame.maxX - 80)
        let itemsWidth = CGFloat(drawerApps.count) * 34
        let contentWidth = drawerApps.isEmpty ? 245 : itemsWidth + 58
        let width = min(contentWidth, min(480, screen.visibleFrame.width - 16))
        let height: CGFloat = 46
        let x = min(max(centerX - width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
        let y = min(screen.visibleFrame.maxY, anchorOnScreen ? anchorY : screen.frame.maxY - NSStatusBar.system.thickness)
        panel.setFrame(NSRect(x: x, y: y - height - 6, width: width, height: height), display: false)
        drawerPresentedAt = ProcessInfo.processInfo.systemUptime
        panel.makeKeyAndOrderFront(nil)
        monitorDrawerClicks()
    }

    func openHiddenApp(_ app: SavedApp) {
        NSLog("MenuDrawer: opening menu for %@", app.id)
        updateAccessibility()
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id)
            .first(where: { !$0.isTerminated }) else {
            menuOpenError = String(localized: "error.appNotRunning", defaultValue: "\(app.name) isn’t running.")
            presentDrawer()
            return
        }
        guard hasAccessibility else {
            reportMenuOpenError(String(localized: "accessibility.permissionRequired"))
            return
        }
        guard preparingAppIDs.isEmpty else { return }
        guard let placement = placements[app.id], placement.pid == running.processIdentifier, placement.ready else {
            reportMenuOpenError(String(
                localized: "error.placeApp",
                defaultValue: "Couldn’t arrange \(app.name). Move it out of the drawer and add it again."
            ))
            return
        }
        let pid = running.processIdentifier
        menuOpenError = nil
        dismissDrawer()
        endInteraction()
        openingAppID = app.id
        syncVisibility()
        let menuBarFrames = self.menuBarFrames
        interactionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let originalWindows = await MenuBarInventory.popupFrames(pid: pid)
            await waitForMenuBarLayout()
            guard !Task.isCancelled else { return }
            let opened: Bool
            let pressed = await MenuBarInventory.press(pid: pid, menuBarFrames: menuBarFrames)
            let openedByPress = pressed
                ? await waitForAppMenu(pid: pid, originalWindows: originalWindows, seconds: 0.45)
                : false
            if openedByPress {
                opened = true
            } else {
                opened = await clickOriginalItem(pid: pid, menuBarFrames: menuBarFrames, originalWindows: originalWindows)
            }
            guard !Task.isCancelled else { return }
            guard opened else {
                NSLog("MenuDrawer: menu did not open for %@", app.id)
                reportMenuOpenError(String(localized: "error.openAppMenu", defaultValue: "Couldn’t open the menu for \(app.name)."))
                return
            }
            NSLog("MenuDrawer: menu opened for %@", app.id)

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let menuOpen = await appMenuIsOpen(pid: pid, originalWindows: originalWindows)
                guard !Task.isCancelled else { return }
                if !menuOpen {
                    endInteraction()
                    syncVisibility()
                    return
                }
            }
        }
    }

    private func reportMenuOpenError(_ message: String) {
        endInteraction()
        syncVisibility()
        menuOpenError = message
        presentDrawer()
    }

    private func waitForMenuBarLayout() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while isApplying && !Task.isCancelled && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func clickOriginalItem(pid: pid_t, menuBarFrames: [CGRect], originalWindows: Set<CGRect>) async -> Bool {
        guard !Task.isCancelled else { return false }
        let point = await MenuBarInventory.renderedItemCenter(pid: pid, menuBarFrames: menuBarFrames)
        guard let point, !Task.isCancelled else { return false }
        if await appMenuIsOpen(pid: pid, originalWindows: originalWindows) { return true }
        guard await MenuBarClick.send(to: point) else { return false }
        return await waitForAppMenu(pid: pid, originalWindows: originalWindows, seconds: 1)
    }

    private func placeAtLeadingEdge(pid: pid_t, menuBarFrames: [CGRect]) async -> Bool {
        guard let frame = await MenuBarInventory.renderedItemFrame(pid: pid, menuBarFrames: menuBarFrames),
              let leading = await MenuBarInventory.leadingItemFrame(in: menuBarFrames, containing: frame)
        else { return false }
        NSLog("MenuDrawer: placement %@, leading %@", NSStringFromRect(frame), NSStringFromRect(leading))
        if frame.minX <= leading.minX + 1 { return true }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let end = CGPoint(x: leading.minX + 1, y: frame.midY)
        guard await MenuBarClick.move(from: start, to: end) else { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !Task.isCancelled {
            if let current = await MenuBarInventory.renderedItemFrame(pid: pid, menuBarFrames: menuBarFrames),
               let first = await MenuBarInventory.leadingItemFrame(in: menuBarFrames, containing: current),
               current.minX <= first.minX + 1 {
                NSLog("MenuDrawer: leading placement confirmed %@", NSStringFromRect(current))
                return true
            }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitForAppMenu(pid: pid_t, originalWindows: Set<CGRect>, seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !Task.isCancelled {
            if await appMenuIsOpen(pid: pid, originalWindows: originalWindows) { return true }
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(75))
        }
        return false
    }

    private func appMenuIsOpen(pid: pid_t, originalWindows: Set<CGRect>) async -> Bool {
        let currentWindows = await MenuBarInventory.popupFrames(pid: pid)
        if !currentWindows.isSubset(of: originalWindows) { return true }
        return await MenuBarInventory.hasOpenMenu(pid: pid)
    }

    private func endInteraction() {
        interactionTask?.cancel()
        interactionTask = nil
        openingAppID = nil
    }

    func showSettings() {
        dismissDrawer()
        defaults.set(true, forKey: "SawLayoutEditor")
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 510),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "layout.title")
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 570, height: 435)
            window.contentViewController = NSHostingController(rootView: SettingsView(controller: self))
            window.center()
            settingsWindow = window
        }
        refreshMenuBarApps()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private final class DrawerPanel: NSPanel {
    var onCancel: (() -> Void)?
    var dismissesOnResignKey = false

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        if dismissesOnResignKey { onCancel?() }
    }
}
