import Foundation

actor FileSearchProbe {
    private var active = 0
    private var calls: [String] = []
    private var maximumActive = 0
    private let pausedQuery: String?
    private var pauseEnabled: Bool
    private var pausedContinuation: CheckedContinuation<Void, Never>?

    init(pausing query: String? = nil) {
        pausedQuery = query
        pauseEnabled = query != nil
    }

    func search(
        query: String, filter: FileSearchFilter, policy: FileSearchPolicy
    ) async -> [FileSearchResult] {
        active += 1
        calls.append(filter == .all ? query : "\(query) [\(filter.title)]")
        maximumActive = max(maximumActive, active)
        if pauseEnabled, query == pausedQuery {
            await withCheckedContinuation { continuation in
                pausedContinuation = continuation
            }
        } else {
            try? await Task.sleep(for: .milliseconds(80))
        }
        active -= 1
        return [
            FileSearchResult(
                url: policy.homeDirectory.appending(path: query), isDirectory: false,
                homeDirectory: policy.homeDirectory)
        ]
    }

    func snapshot() -> (calls: [String], maximumActive: Int) {
        (calls, maximumActive)
    }

    func waitUntilPaused() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while pausedContinuation == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard pausedContinuation != nil else {
            pauseEnabled = false
            return false
        }
        return true
    }

    func resumePausedSearch() {
        pauseEnabled = false
        pausedContinuation?.resume()
        pausedContinuation = nil
    }
}

actor ContentProbe {
    private var calls = 0
    private var pauseEnabled: Bool
    private var pausedContinuation: CheckedContinuation<Void, Never>?

    init(pausing: Bool) { pauseEnabled = pausing }

    func search(
        query: String, policy: FileSearchPolicy, names: [FileSearchResult]
    ) async -> [FileSearchResult] {
        calls += 1
        if pauseEnabled {
            await withCheckedContinuation { pausedContinuation = $0 }
        }
        return names + [
            FileSearchResult(
                url: policy.homeDirectory.appending(path: "\(query) (content)"), isDirectory: false,
                homeDirectory: policy.homeDirectory)
        ]
    }

    func callCount() -> Int { calls }

    func waitUntilPaused() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while pausedContinuation == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return pausedContinuation != nil
    }

    func resume() {
        pauseEnabled = false
        pausedContinuation?.resume()
        pausedContinuation = nil
    }
}

@main
@MainActor
struct FileSearchSessionTests {
    nonisolated(unsafe) static var failures = 0
    static let home = URL(fileURLWithPath: "/Users/test")

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        await coalescesDebouncingQueries()
        await serializesRunningQueries()
        await cancellationPreventsPendingWork()
        await policyChangeDiscardsStaleResults()
        await unchangedPolicyKeepsResults()
        await blankQueryLoadsRecents()
        await filterChangeRerunsTheQuery()
        await contentPassMergesAfterNames()
        await newerQuerySkipsTheContentPass()
        await contentPassOnlyWhenEnabled()

        print(failures == 0 ? "File search session tests passed" : "\(failures) tests failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func coalescesDebouncingQueries() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe, debounce: .milliseconds(30))
        session.search("annual")
        session.search("annual report")
        await waitUntil { session.state == .ready }

        let snapshot = await probe.snapshot()
        expect(snapshot.calls == ["annual report"], "the debounce runs only the newest query")
        expect(session.results.first?.name == "annual report", "the newest query publishes")
    }

    static func serializesRunningQueries() async {
        let probe = FileSearchProbe(pausing: "first")
        let session = makeSession(probe: probe, debounce: .milliseconds(10))
        session.search("first")
        let firstStarted = await probe.waitUntilPaused()
        expect(firstStarted, "the first query starts")
        guard firstStarted else { return }
        session.search("second")
        await probe.resumePausedSearch()
        await waitUntil { session.state == .ready && session.results.first?.name == "second" }

        let snapshot = await probe.snapshot()
        expect(snapshot.calls == ["first", "second"], "the superseding query still runs")
        expect(snapshot.maximumActive == 1, "Spotlight operations never overlap")
    }

    static func cancellationPreventsPendingWork() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe, debounce: .milliseconds(30))
        session.search("cancelled")
        session.cancel()
        try? await Task.sleep(for: .milliseconds(60))

        let snapshot = await probe.snapshot()
        expect(snapshot.calls.isEmpty, "cancelling during the debounce prevents the search")
        expect(session.state == .idle && session.results.isEmpty, "cancellation clears the session")
    }

    static func policyChangeDiscardsStaleResults() async {
        let probe = FileSearchProbe(pausing: "report")
        let session = makeSession(probe: probe, debounce: .milliseconds(10))
        session.search("report")
        let oldSearchStarted = await probe.waitUntilPaused()
        expect(oldSearchStarted, "the old-policy query starts")
        guard oldSearchStarted else { return }
        session.apply(scopes: FileSearchScope.defaultScopes, ignorePatterns: ["*.log"])

        expect(
            session.state == .idle && session.results.isEmpty,
            "a result found under the old rules never publishes")
        session.search("report")
        await probe.resumePausedSearch()
        await waitUntil { session.state == .ready && session.results.first?.name == "report" }
        let snapshot = await probe.snapshot()
        expect(snapshot.calls == ["report", "report"], "the same query re-runs under the new rules")
    }

    static func unchangedPolicyKeepsResults() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe, debounce: .milliseconds(10))
        session.search("report")
        await waitUntil { session.state == .ready }
        session.apply(scopes: FileSearchScope.defaultScopes, ignorePatterns: [])

        expect(
            session.state == .ready && session.results.first?.name == "report",
            "re-applying identical settings leaves the published results alone")
    }

    static func blankQueryLoadsRecents() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe, debounce: .milliseconds(10))
        session.search("")
        await waitUntil { session.state == .ready }
        session.search("report")
        await waitUntil { session.state == .ready && session.results.first?.name == "report" }

        let snapshot = await probe.snapshot()
        expect(
            snapshot.calls == ["", "report"],
            "the blank screen is a request of its own, not the absence of one")
    }

    static func filterChangeRerunsTheQuery() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe, debounce: .milliseconds(10))
        session.search("report")
        await waitUntil { session.state == .ready }
        session.search("report", filter: .images)
        await waitUntil { session.state == .ready }
        session.search("report", filter: .images)
        try? await Task.sleep(for: .milliseconds(40))

        let snapshot = await probe.snapshot()
        expect(
            snapshot.calls == ["report", "report [Images]"],
            "narrowing the filter re-runs the same words, and re-stating it runs nothing")
    }

    static func contentPassMergesAfterNames() async {
        let probe = FileSearchProbe()
        let content = ContentProbe(pausing: true)
        let session = makeSession(probe: probe, content: content, debounce: .milliseconds(10))
        session.search("budget")
        await waitUntil { session.state == .ready }
        expect(
            session.results.map(\.name) == ["budget"],
            "the name matches publish before the content pass returns")
        let started = await content.waitUntilPaused()
        expect(started, "the content pass starts after the names publish")
        await content.resume()
        await waitUntil { session.results.count == 2 }
        expect(
            session.results.map(\.name) == ["budget", "budget (content)"],
            "the content matches merge in under the name matches")
    }

    static func newerQuerySkipsTheContentPass() async {
        let probe = FileSearchProbe()
        let content = ContentProbe(pausing: true)
        let session = makeSession(probe: probe, content: content, debounce: .milliseconds(10))
        session.search("budget")
        _ = await content.waitUntilPaused()
        session.search("invoice")
        await content.resume()
        await waitUntil { session.state == .ready && session.results.first?.name == "invoice" }
        try? await Task.sleep(for: .milliseconds(40))
        expect(
            !session.results.contains { $0.name == "budget (content)" },
            "a superseded query's content matches never publish")
    }

    static func contentPassOnlyWhenEnabled() async {
        let probe = FileSearchProbe()
        let content = ContentProbe(pausing: false)
        let policy = FileSearchPolicy(
            scopes: FileSearchScope.defaultScopes, ignorePatterns: [], homeDirectory: home)
        let session = FileSearchSession(
            policy: policy, debounce: .milliseconds(10),
            contentOperation: { query, _, policy, names in
                await content.search(query: query, policy: policy, names: names)
            },
            searchOperation: { query, filter, policy in
                await probe.search(query: query, filter: filter, policy: policy)
            })
        session.search("")
        await waitUntil { session.state == .ready }
        session.search("budget")
        await waitUntil { session.state == .ready && session.results.first?.name == "budget" }
        try? await Task.sleep(for: .milliseconds(40))
        let calls = await content.callCount()
        expect(calls == 0, "with content search off, and on the blank screen, no content pass runs")
    }

    static func makeSession(
        probe: FileSearchProbe, content: ContentProbe, debounce: Duration
    ) -> FileSearchSession {
        let policy = FileSearchPolicy(
            scopes: FileSearchScope.defaultScopes, ignorePatterns: [], homeDirectory: home,
            includesContent: true)
        return FileSearchSession(
            policy: policy, debounce: debounce,
            contentOperation: { query, _, policy, names in
                await content.search(query: query, policy: policy, names: names)
            },
            searchOperation: { query, filter, policy in
                await probe.search(query: query, filter: filter, policy: policy)
            })
    }

    static func makeSession(probe: FileSearchProbe, debounce: Duration) -> FileSearchSession {
        let policy = FileSearchPolicy(
            scopes: FileSearchScope.defaultScopes, ignorePatterns: [], homeDirectory: home)
        return FileSearchSession(policy: policy, debounce: debounce) { query, filter, policy in
            await probe.search(query: query, filter: filter, policy: policy)
        }
    }

    static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect(condition(), "the async operation completed before the timeout")
    }
}
