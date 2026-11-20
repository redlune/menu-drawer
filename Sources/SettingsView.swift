import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var controller: DrawerController
    @Environment(\.colorScheme) private var colorScheme
    @State private var search = ""
    @State private var showAllRunning = false
    @State private var hoveringDrawer = false
    @State private var hoveringMenuBar = false

    private static let dragType = UTType(exportedAs: "local.yubi.menudrawer.app", conformingTo: .data)
    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.70, green: 0.66, blue: 1)
            : Color(red: 0.34, green: 0.31, blue: 0.84)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let noticeText {
                Label(noticeText, systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 14) {
                column(
                    title: showAllRunning || !controller.hasAccessibility ? "layout.runningApps" : "layout.menuBar",
                    icon: "menubar.rectangle",
                    apps: visibleApps,
                    isHidden: false
                )
                column(title: "layout.drawer", icon: "tray.fill", apps: controller.hiddenApps, isHidden: true)
            }

            Divider()
            footer
        }
        .padding(22)
        .frame(minWidth: 550, minHeight: 390)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("layout.title")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("layout.dragHelp")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if controller.hasAccessibility {
                    Toggle("layout.showAllRunning", isOn: $showAllRunning)
                }
                Button("layout.refresh") { controller.refreshMenuBarApps(retryFailedPlacements: true) }
                Divider()
                CheckForUpdatesButton(updater: controller.updater)
                Button("app.quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("layout.options")
        }
    }

    private var noticeText: String? {
        if controller.installationRequired {
            return String(localized: "error.installationRequired")
        }
        if !controller.canHide {
            return String(localized: "error.unsupportedOS")
        }
        return controller.errorMessage
    }

    private func column(title: LocalizedStringKey, icon: String, apps: [SavedApp], isHidden: Bool) -> some View {
        let target = isHidden ? $hoveringDrawer : $hoveringMenuBar
        return VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if !isHidden {
                TextField("layout.search", text: $search)
                    .textFieldStyle(.roundedBorder)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(apps) { app in
                        row(app, isHidden: isHidden)
                    }
                    if apps.isEmpty {
                        emptyState(isHidden: isHidden)
                    }
                }
                .padding(3)
            }
            .defaultScrollAnchor(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            target.wrappedValue ? accent.opacity(0.13) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(target.wrappedValue ? accent : .secondary.opacity(0.16), lineWidth: target.wrappedValue ? 2 : 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onDrop(of: [Self.dragType], isTargeted: target) { [weak controller = controller] providers in
            guard let provider = providers.first, provider.hasItemConformingToTypeIdentifier(Self.dragType.identifier) else {
                return false
            }
            provider.loadDataRepresentation(forTypeIdentifier: Self.dragType.identifier) { [weak controller = controller] data, _ in
                guard let data, let id = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { [weak controller = controller] in controller?.moveApp(id: id, toDrawer: isHidden) }
            }
            return true
        }
    }

    @ViewBuilder private func emptyState(isHidden: Bool) -> some View {
        if isHidden {
            Label("layout.dropHere", systemImage: "tray.and.arrow.down")
                .padding(.vertical, 22)
        } else if controller.isScanning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("layout.scanning")
            }
            .padding(.vertical, 8)
        } else {
            Text(search.isEmpty ? String(localized: "layout.noApps") : String(localized: "layout.noSearchResults"))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    private func row(_ app: SavedApp, isHidden: Bool) -> some View {
        let actionHelp: LocalizedStringKey = isHidden ? "layout.moveToMenuBar" : "layout.moveToDrawer"
        let actionLabel = isHidden
            ? String(localized: "layout.moveAppToMenuBar", defaultValue: "Show \(app.name) in the menu bar")
            : String(localized: "layout.moveAppToDrawer", defaultValue: "Move \(app.name) to the drawer")
        return HStack(spacing: 9) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 25, height: 25)
                .accessibilityHidden(true)
            Text(app.name).lineLimit(1)
            Spacer()
            Button {
                controller.setHidden(app, to: !isHidden)
            } label: {
                Image(systemName: isHidden ? "arrow.left" : "arrow.right")
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.borderless)
            .help(actionHelp)
            .accessibilityLabel(actionLabel)
        }
        .padding(7)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onDrag {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: Self.dragType.identifier, visibility: .ownProcess) { completion in
                completion(Data(app.id.utf8), nil)
                return nil
            }
            return provider
        }
    }

    private var footer: some View {
        HStack {
            if !controller.hasAccessibility {
                Button("layout.openAccessibilitySettings") { controller.requestAccessibility() }
                    .help("layout.accessibilityHelp")
            } else {
                Label("layout.menuBarDragHelp", systemImage: "command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("layout.autoHide", selection: $controller.autoCollapseDelay) {
                Text("layout.autoHide.off").tag(0)
                Text("layout.autoHide.tenSeconds").tag(10)
                Text("layout.autoHide.thirtySeconds").tag(30)
                Text("layout.autoHide.oneMinute").tag(60)
            }
            .fixedSize()
        }
    }

    private var visibleApps: [SavedApp] {
        let hidden = Set(controller.hiddenApps.map(\.id))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        return controller.runningApps.map(\.app).filter { app in
            !hidden.contains(app.id)
                && (showAllRunning || !controller.hasAccessibility || controller.menuBarAppIDs.contains(app.id))
                && (query.isEmpty || app.name.localizedCaseInsensitiveContains(query))
                && seen.insert(app.id).inserted
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
