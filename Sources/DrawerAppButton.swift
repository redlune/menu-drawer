import AppKit
import SwiftUI

struct DrawerAppButton: NSViewRepresentable {
    let app: SavedApp
    let isPreparing: Bool
    let open: () -> Void
    let keepVisible: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = FirstClickButton()
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu)
        let menu = NSMenu()
        let item = NSMenuItem(title: String(localized: "drawer.pinApp"), action: #selector(Coordinator.pin), keyEquivalent: "")
        item.target = context.coordinator
        menu.addItem(item)
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.open = open
        context.coordinator.keepVisible = keepVisible
        let icon = app.icon.copy() as! NSImage
        icon.size = NSSize(width: 20, height: 20)
        button.image = icon
        button.isEnabled = !isPreparing
        button.toolTip = isPreparing
            ? String(localized: "drawer.preparingApp", defaultValue: "Adding \(app.name) to the drawer…")
            : app.name
        button.setAccessibilityLabel(String(localized: "drawer.openAppMenu", defaultValue: "Open menu for \(app.name)"))
        button.identifier = NSUserInterfaceItemIdentifier(app.id)
    }

    @MainActor
    final class Coordinator: NSObject {
        var open: (() -> Void)?
        var keepVisible: (() -> Void)?

        @objc func openMenu() { open?() }
        @objc func pin() { keepVisible?() }
    }
}

private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
