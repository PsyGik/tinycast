import Foundation

@MainActor
@Observable
final class FileSearchSession {
    typealias SearchOperation =
        @Sendable (String, FileSearchFilter, FileSearchPolicy) async throws -> [FileSearchResult]
    /// The name matches go in, and come back merged with the content matches and re-ranked.
    typealias ContentOperation =
        @Sendable (String, FileSearchFilter, FileSearchPolicy, [FileSearchResult]) async throws
        -> [FileSearchResult]

    enum State: Equatable {
        case idle
        case searching
        case ready
        case failed
    }

    private(set) var results: [FileSearchResult] = []
    private(set) var state: State = .idle
    /// The published search: the filter belongs to it, so narrowing re-runs the same words.
    private var request: Request?
    private var revision = 0
    @ObservationIgnored private var pendingSearch: PendingSearch?
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    @ObservationIgnored private let homeDirectory: URL
    @ObservationIgnored private var policy: FileSearchPolicy
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let searchOperation: SearchOperation
    @ObservationIgnored private let contentOperation: ContentOperation?

    private struct Request: Equatable {
        let query: String
        let filter: FileSearchFilter
    }

    private struct PendingSearch {
        let request: Request
        let revision: Int
        let earliestStart: ContinuousClock.Instant
    }

    init() {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.homeDirectory = homeDirectory
        policy = FileSearchPolicy(
            scopes: FileSearchScope.defaultScopes, ignorePatterns: [],
            homeDirectory: homeDirectory)
        debounce = .milliseconds(120)
        searchOperation = { query, filter, policy in
            try await Task.detached(priority: .userInitiated) {
                try FileSearchService.search(query: query, policy: policy, filter: filter)
            }.value
        }
        contentOperation = { query, filter, policy, names in
            try await Task.detached(priority: .userInitiated) {
                try FileSearchService.contentSearch(
                    query: query, policy: policy, filter: filter, merging: names)
            }.value
        }
    }

    init(
        policy: FileSearchPolicy, debounce: Duration, contentOperation: ContentOperation? = nil,
        searchOperation: @escaping SearchOperation
    ) {
        homeDirectory = policy.homeDirectory
        self.policy = policy
        self.debounce = debounce
        self.searchOperation = searchOperation
        self.contentOperation = contentOperation
    }

    /// Resolved here rather than per search, so glob compilation stays off the keystroke path.
    func apply(
        scopes: [String], ignorePatterns: [String], includesContent: Bool = false,
        resultLimit: Int = FileSearchQuery.resultLimit
    ) {
        let policy = FileSearchPolicy(
            scopes: scopes, ignorePatterns: ignorePatterns, homeDirectory: homeDirectory,
            includesContent: includesContent, resultLimit: resultLimit)
        guard policy != self.policy else { return }
        self.policy = policy
        // A result found under the old rules must not publish, and the same query has to re-run.
        cancel()
    }

    /// An empty query is a request too: the blank screen lists what was used recently.
    func search(_ rawQuery: String, filter: FileSearchFilter = .all) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = Request(query: query, filter: filter)
        guard request != self.request || state == .failed else { return }
        revision &+= 1
        self.request = request
        state = .searching
        // No debounce on the blank screen: there is no next keystroke for it to coalesce with.
        pendingSearch = PendingSearch(
            request: request, revision: revision,
            earliestStart: ContinuousClock.now.advanced(by: query.isEmpty ? .zero : debounce))
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            guard let self else { return }
            await runWorker()
        }
    }

    func cancel() {
        revision &+= 1
        pendingSearch = nil
        request = nil
        results = []
        state = .idle
    }

    /// A trashed row names a file that is gone, so it leaves the published results with it.
    func remove(_ result: FileSearchResult) {
        results.removeAll { $0.id == result.id }
    }

    private func runWorker() async {
        while let pending = pendingSearch {
            let delay = ContinuousClock.now.duration(to: pending.earliestStart)
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard pendingSearch?.revision == pending.revision else { continue }
            pendingSearch = nil
            let request = pending.request
            do {
                let candidates = try await searchOperation(request.query, request.filter, policy)
                guard revision == pending.revision, self.request == request else { continue }
                results = candidates
                state = .ready
                // Names publish first; a newer keystroke waiting means this content pass is moot.
                guard pendingSearch == nil, policy.includesContent, !request.query.isEmpty,
                    candidates.count < policy.resultLimit, let contentOperation
                else { continue }
                let merged = try? await contentOperation(
                    request.query, request.filter, policy, candidates)
                guard let merged, revision == pending.revision, self.request == request else {
                    continue
                }
                results = merged
            } catch {
                guard revision == pending.revision, self.request == request else { continue }
                results = []
                state = .failed
            }
        }
        workerTask = nil
    }
}
