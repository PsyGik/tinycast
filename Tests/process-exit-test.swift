// Waiting for a child through `ProcessExit` never misses its exit (#1184), even 16 at a time on GCD.
import Foundation
import Synchronization

@main
struct ProcessExitTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ description: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)  \(detail())")
            failures += 1
        }
    }

    static func launch(_ path: String, _ arguments: [String] = []) -> (Process, ProcessExit)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard let exit = try? process.runObservingExit() else { return nil }
        return (process, exit)
    }

    static func main() {
        statusAndRepeatedWaits()
        concurrentBurst()
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func statusAndRepeatedWaits() {
        guard let (process, exit) = launch("/bin/sh", ["-c", "exit 3"]) else {
            check("a child launches", false)
            return
        }
        exit.wait()
        check("the child's status is read after the wait", process.terminationStatus == 3,
              "got \(process.terminationStatus)")
        exit.wait()
        check("a second wait returns at once rather than blocking", true)
        let late = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            exit.wait()
            late.signal()
        }
        check("a wait from another thread after the exit returns",
              late.wait(timeout: .now() + 5) == .success)
    }

    /// The issue's shape: short children launched and waited on GCD worker threads, 16 in flight.
    static func concurrentBurst() {
        let total = 1_500
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: 16)
        let tally = Mutex((finished: 0, failed: 0))
        for _ in 0..<total {
            slots.wait()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    slots.signal()
                    group.leave()
                }
                guard let (_, exit) = launch("/usr/bin/true") else {
                    tally.withLock { $0.failed += 1 }
                    return
                }
                exit.wait()
                tally.withLock { $0.finished += 1 }
            }
        }
        let settled = group.wait(timeout: .now() + 120) == .success
        let (done, failed) = tally.withLock { ($0.finished, $0.failed) }
        check("every one of \(total) concurrent waits returns", settled && done + failed == total,
              "\(done) finished, \(failed) failed to launch, \(total - done - failed) still waiting")
        check("no launch failed", failed == 0, "\(failed) failed")
    }
}
