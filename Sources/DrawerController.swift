import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class DrawerController: NSObject, NSApplicationDelegate, @preconcurrency NSStatusItemExpandedInterfaceDelegate, ObservableObject {
    private struct PlacementRequest: Equatable {
        let id = UUID()
        let appID: String
        let pid: pid_t
    }

    @Published private(set) var hiddenApps: [SavedApp] = []
    @Published private(set) var runningApps: [RunningApp] = []
    @Published private(set) var menuBarAppIDs: Set<String> = []
    @Published private(set) var hasAccessibility = false
    @Published private(set) var isScanning = false
    @Published private(set) var isCollapsed = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var menuOpenError: String?
    @Published private var preparingApps: [String: PlacementRequest] = [:]
    @Published var autoCollapseDelay = 0 {
        didSet {
            defaults.set(autoCollapseDelay, forKey: "AutoCollapseDelay")
            scheduleAutoCollapse()
        }
    }

    private let defaults = UserDefaults.standard
    let updater = AppUpdater()
    private let bundleID = Bundle.main.bundleIdentifier ?? "local.yubi.MenuDrawer"
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var drawerPanel: DrawerPanel?
    private let dragMonitor = MenuBarDragMonitor()
    private var accessTimer: Timer?
    private var interactionTask: Task<Void, Never>?
    private var openingAppID: String?
    private var placementQueue: [PlacementRequest] = []
    private var placementTask: Task<Void, Never>?
    private var placementGeneration = UUID()
    private var placements: [String: (pid: pid_t, ready: Bool)] = [:]
    private var lastLayoutScanPIDs: Set<pid_t> = []
    private var runningObservation: NSKeyValueObservation?
    private var scanTask: Task<Void, Never>?
    private var autoCollapseTimer: Timer?
    private var wantsCollapsed = false
    private let visibility = MenuBarVisibility()

    var installationRequired: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return !path.hasPrefix("/Applications/")
    }

    var canHide: Bool {
        !installationRequired && VisibilityBridge.isAvailable()
    }

    var drawerApps: [SavedApp] {
        let running = Dictionary(runningApps.map { ($0.app.id, $0.app) }, uniquingKeysWith: { first, _ in first })
        return hiddenApps.compactMap { running[$0.id] }
    }

    var isPreparingApps: Bool { !preparingApps.isEmpty }

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
        updater.start()
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
        drawerPanel?.hide()
    }

    func dismissDrawer() {
        drawerPanel?.hide()
        statusItem?.expandedInterfaceSession?.cancel()
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
        } else {
            hiddenApps.removeAll { $0.id == app.id }
            menuBarAppIDs.insert(app.id)
            placementQueue.removeAll { $0.appID == app.id }
            preparingApps.removeValue(forKey: app.id)
        }
        placements.removeValue(forKey: app.id)
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

    func refreshMenuBarApps(retryFailedPlacements: Bool = false) {
        if retryFailedPlacements { placements = placements.filter { $0.value.ready } }
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
        let hidden = Set(hiddenApps.lazy.map(\.id).filter { id in
            self.placements[id]?.ready == true && id != self.openingAppID
        })
        guard !running.isDisjoint(with: hidden) else {
            visibility.restore()
            isCollapsed = true
            updateStatusItem()
            return
        }

        let allowed = running.subtracting(hidden).union([bundleID])
        visibility.restrict(to: allowed) { [weak self] applied in
            guard let self else { return }
            if applied {
                isCollapsed = true
                updateStatusItem()
            } else {
                failToHide()
            }
        }
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
        visibility.restore()
        isCollapsed = false
        updateStatusItem()
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
            placements = placements.filter { $0.value.ready }
            prepareHiddenApps()
            dragMonitor.start(
                candidates: { [weak self] in
                    guard let self else { return [] }
                    guard self.isCollapsed else { return self.runningApps }
                    return self.runningApps.filter { self.placements[$0.app.id]?.ready != true }
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
                  preparingApps[app.id] == nil else { continue }
            let request = PlacementRequest(appID: app.id, pid: running.pid)
            preparingApps[app.id] = request
            placementQueue.append(request)
        }
        guard placementTask == nil, !placementQueue.isEmpty else { return }
        let generation = UUID()
        placementGeneration = generation
        placementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !placementQueue.isEmpty {
                await place(placementQueue.removeFirst())
            }
            guard placementGeneration == generation else { return }
            placementTask = nil
            prepareHiddenApps()
        }
    }

    private func place(_ request: PlacementRequest) async {
        defer {
            if preparingApps[request.appID] == request {
                preparingApps.removeValue(forKey: request.appID)
                syncVisibility()
            }
        }
        // Leave user drags and in-use menus alone while waiting to arrange the icon.
        while isCurrentPlacement(request), openingAppID != nil
            || CGEventSource.buttonState(.combinedSessionState, button: .left) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard isCurrentPlacement(request) else { return }
        syncVisibility()
        await waitForMenuBarLayout()
        guard isCurrentPlacement(request) else { return }
        let ready = await MenuBarItemInteraction.moveToLeadingEdge(pid: request.pid, menuBarFrames: menuBarFrames) {
            self.isCurrentPlacement(request)
        }
        if isCurrentPlacement(request) { placements[request.appID] = (request.pid, ready) }
    }

    private func isCurrentPlacement(_ request: PlacementRequest) -> Bool {
        !Task.isCancelled && preparingApps[request.appID] == request
            && runningApps.contains { $0.app.id == request.appID && $0.pid == request.pid }
    }

    private func cancelPlacement() {
        placementGeneration = UUID()
        placementTask?.cancel()
        placementTask = nil
        placementQueue = []
        preparingApps = [:]
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
            drawerPanel = DrawerPanel(content: NSHostingController(rootView: DrawerView(controller: self))) { [weak self] in
                self?.dismissDrawer()
            }
        }
        drawerPanel?.present(
            anchor: menuBarAnchor(),
            appCount: drawerApps.count,
            dismissesOnResignKey: statusItem?.expandedInterfaceSession == nil
        )
    }

    func openHiddenApp(_ app: SavedApp) {
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
        guard !isPreparingApps else { return }
        guard let placement = placements[app.id], placement.pid == running.processIdentifier, placement.ready else {
            reportMenuOpenError(String(
                localized: "error.placeApp",
                defaultValue: "Couldn’t arrange \(app.name). Check the menu bar or refresh the layout to try again."
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
            let originalWindows = await MenuBarInventory.windowIDs(pid: pid)
            await waitForMenuBarLayout()
            guard !Task.isCancelled else { return }
            let menu = await MenuBarItemInteraction.openMenu(
                pid: pid, menuBarFrames: menuBarFrames, originalWindows: originalWindows
            )
            guard !Task.isCancelled else { return }
            guard let menu else {
                reportMenuOpenError(String(localized: "error.openAppMenu", defaultValue: "Couldn’t open the menu for \(app.name)."))
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let menuOpen = await MenuBarItemInteraction.menuIsOpen(pid: pid, menu: menu)
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
        while visibility.isApplying && !Task.isCancelled && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(200))
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
