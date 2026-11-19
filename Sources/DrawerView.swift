import SwiftUI

struct DrawerView: View {
    @ObservedObject var controller: DrawerController

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(controller.drawerApps) { app in
                        DrawerAppButton(
                            app: app,
                            isPreparing: !controller.preparingAppIDs.isEmpty,
                            open: { controller.openHiddenApp(app) },
                            keepVisible: { controller.setHidden(app, to: false) }
                        )
                        .frame(width: 32, height: 30)
                    }
                    if controller.drawerApps.isEmpty {
                        Text("drawer.empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Divider().frame(height: 16).padding(.horizontal, 3)
            Menu {
                if let message = controller.menuOpenError {
                    Text(message)
                    Divider()
                }
                Button("drawer.openLayout") { controller.showSettings() }
                if !controller.hasAccessibility {
                    Button("drawer.openAccessibilitySettings") { controller.requestAccessibility() }
                }
                Divider()
                Button(controller.isCollapsed ? String(localized: "drawer.expand") : String(localized: "drawer.collapse")) {
                    controller.toggle()
                    controller.dismissDrawer()
                }
                Button("app.quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: controller.menuOpenError == nil ? "ellipsis" : "exclamationmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(controller.menuOpenError ?? String(localized: "drawer.options"))
            .accessibilityLabel("drawer.options")
        }
        .padding(.horizontal, 7)
        .frame(height: 40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(0.14))
                .allowsHitTesting(false)
        }
        .padding(3)
    }
}
