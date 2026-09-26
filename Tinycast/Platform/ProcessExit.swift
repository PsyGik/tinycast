import Foundation

/// A child's exit, via `terminationHandler`: `waitUntilExit()` can miss it on a GCD thread (#1184).
final class ProcessExit: Sendable {
    private let exited = DispatchSemaphore(value: 0)

    /// Before `run()`: a handler installed after the child has exited never fires.
    init(of process: Process) {
        let exited = exited
        process.terminationHandler = { _ in exited.signal() }
    }

    /// Blocks until the child has exited; re-signals, so any later or concurrent wait returns too.
    func wait() {
        exited.wait()
        exited.signal()
    }
}
