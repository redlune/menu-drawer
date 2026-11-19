import CoreGraphics

enum MenuBarClick {
    static let eventMarker: Int64 = 0x4D656E7544726177

    @MainActor
    static func move(from start: CGPoint, to end: CGPoint) async -> Bool {
        guard !Task.isCancelled,
              CGPreflightPostEventAccess(),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              let original = CGEvent(source: nil)?.location,
              let source = CGEventSource(stateID: .combinedSessionState)
        else { return false }
        source.localEventsSuppressionInterval = 0
        func event(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
            let value = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            value?.flags = .maskCommand
            value?.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            value?.setIntegerValueField(.mouseEventClickState, value: 1)
            return value
        }
        guard let down = event(.leftMouseDown, at: start),
              let up = event(.leftMouseUp, at: end) else { return false }
        down.post(tap: .cgSessionEventTap)
        try? await Task.sleep(for: .milliseconds(70))
        var last = start
        for step in 1...10 where !Task.isCancelled {
            let fraction = CGFloat(step) / 10
            last = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y)
            guard let drag = event(.leftMouseDragged, at: last) else { break }
            drag.post(tap: .cgSessionEventTap)
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Always release the synthetic mouse button, including on cancellation.
        up.location = last
        up.post(tap: .cgSessionEventTap)
        try? await Task.sleep(for: .milliseconds(120))
        if let current = CGEvent(source: nil)?.location, hypot(current.x - last.x, current.y - last.y) < 2 {
            CGWarpMouseCursorPosition(original)
        }
        return !Task.isCancelled
    }

    @MainActor
    static func send(to point: CGPoint) async -> Bool {
        guard !Task.isCancelled,
              CGPreflightPostEventAccess(),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              let original = CGEvent(source: nil)?.location,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return false }

        source.localEventsSuppressionInterval = 0
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        down.post(tap: .cgSessionEventTap)
        try? await Task.sleep(for: .milliseconds(55))
        up.post(tap: .cgSessionEventTap)
        try? await Task.sleep(for: .milliseconds(100))
        if let current = CGEvent(source: nil)?.location, hypot(current.x - point.x, current.y - point.y) < 2 {
            CGWarpMouseCursorPosition(original)
        }
        return true
    }
}
