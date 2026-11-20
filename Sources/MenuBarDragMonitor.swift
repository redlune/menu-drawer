import AppKit

@MainActor
final class MenuBarDragMonitor {
    private struct Drag {
        let id = UUID()
        let start: CGPoint
        let source: Task<[SavedApp], Never>
    }

    private var observation: Any?
    private var drag: Drag?
    private var generation: UUID?

    func start(
        candidates: @escaping () -> [RunningApp],
        anchor: @escaping () -> CGRect?,
        didDrop: @escaping (SavedApp) -> Void
    ) {
        guard observation == nil else { return }
        observation = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let cgEvent = event.cgEvent,
                      cgEvent.getIntegerValueField(.eventSourceUserData) != MenuBarClick.eventMarker else { return }
                let point = cgEvent.location
                switch event.type {
                case .leftMouseDown:
                    self.drag?.source.cancel()
                    self.drag = nil
                    self.generation = nil
                    guard event.modifierFlags.contains(.command),
                          let button = anchor(),
                          abs(button.midY - point.y) <= button.height / 2,
                          !button.contains(point) else { return }
                    let apps = candidates()
                    let source = Task {
                        await MenuBarInventory.apps(at: point, candidates: apps)
                    }
                    let drag = Drag(start: point, source: source)
                    self.generation = drag.id
                    self.drag = drag
                case .leftMouseUp:
                    guard let drag = self.drag else { return }
                    self.drag = nil
                    guard let button = anchor(), Self.isDrawerDrop(from: drag.start, to: point, button: button) else {
                        drag.source.cancel()
                        return
                    }
                    let droppedAt = event.timestamp
                    Task { @MainActor [weak self] in
                        let matches = await drag.source.value
                        guard self?.generation == drag.id,
                              ProcessInfo.processInfo.systemUptime - droppedAt < 2,
                              let first = matches.first,
                              matches.allSatisfy({ $0.id == first.id }) else { return }
                        didDrop(first)
                    }
                default:
                    break
                }
            }
        }
    }

    func stop() {
        if let observation { NSEvent.removeMonitor(observation) }
        observation = nil
        drag?.source.cancel()
        drag = nil
        generation = nil
    }

    static func isDrawerDrop(from start: CGPoint, to end: CGPoint, button: CGRect) -> Bool {
        let dropZone = CGRect(
            x: button.minX - 48, y: button.minY,
            width: button.width + 48, height: button.height
        )
        return dropZone.contains(end) && abs(start.x - end.x) >= 10
    }
}
