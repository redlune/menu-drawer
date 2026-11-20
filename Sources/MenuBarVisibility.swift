import Foundation

@MainActor
final class MenuBarVisibility {
    private struct Restriction {
        let bundles: Set<String>
        let token: NSObject
    }

    private struct Request {
        let id: UUID
        let restriction: Restriction
        let timeout: DispatchWorkItem
        let completion: (Bool) -> Void
    }

    private var active: Restriction?
    private var pending: Request?

    var isApplying: Bool { pending != nil }

    func restrict(to bundles: Set<String>, completion: @escaping (Bool) -> Void) {
        guard bundles != pending?.restriction.bundles else { return }
        cancelPendingRequest()
        guard bundles != active?.bundles else { return }

        let id = UUID()
        guard let token = VisibilityBridge.restrict(toBundles: bundles.sorted(), completion: { [weak self] error in
            self?.finish(id, succeeded: error == nil, error: error)
        }) else {
            completion(false)
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(id, succeeded: false)
        }
        pending = Request(id: id, restriction: Restriction(bundles: bundles, token: token),
                          timeout: timeout, completion: completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    func restore() {
        cancelPendingRequest()
        if let active {
            VisibilityBridge.restore(active.token)
            self.active = nil
        }
    }

    private func finish(_ id: UUID, succeeded: Bool, error: Error? = nil) {
        guard let pending, pending.id == id else { return }
        pending.timeout.cancel()
        self.pending = nil
        if succeeded {
            if let active { VisibilityBridge.restore(active.token) }
            active = pending.restriction
        } else {
            if let error { NSLog("Menu bar visibility request failed: %@", error.localizedDescription) }
            VisibilityBridge.restore(pending.restriction.token)
        }
        pending.completion(succeeded)
    }

    private func cancelPendingRequest() {
        guard let pending else { return }
        pending.timeout.cancel()
        self.pending = nil
        VisibilityBridge.restore(pending.restriction.token)
    }
}
