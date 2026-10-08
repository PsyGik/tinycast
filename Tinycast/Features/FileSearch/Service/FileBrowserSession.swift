import Darwin
import Foundation

/// The folder the browser shows, and what typing finds beneath it. Nothing outlives the visit.
@MainActor
@Observable
final class FileBrowserSession {
    enum State: Equatable {
        case loading
        case ready
        /// macOS refused the read: a protected folder the user has not allowed, or no permission.
        case denied
        case missing
    }

    private(set) var directory: URL
    private(set) var state: State = .loading
    private(set) var listing = FileBrowserListing(
        [], filter: "", showsHidden: false, showsExcluded: false, ignore: FileSearchIgnoreList(patterns: []))
    /// What the list shows: the folder itself, or with text typed, the matches below it.
    private(set) var rows: [FileSearchResult] = []
    /// Bumped with every new `rows`, so the palette lands the highlight once per new list.
    private(set) var rowsRevision = 0
    /// Nil while the folder itself is listed.
    private(set) var searchQuery: String?
    /// What follows the path in the field; empty while the folder itself is listed.
    private(set) var filter = ""
    /// True until the subtree has answered; the folder's own matches show in the meantime.
    private(set) var isSearching = false
    /// The folder just left, so going up lands on it rather than on the first row.
    private(set) var revealedName: String?
    var showsExcluded = false {
        didSet { if showsExcluded != oldValue { relist() } }
    }
    /// The header's type filter: it narrows the folder's files and every search below it.
    var typeFilter: FileSearchFilter = .all {
        didSet {
            guard typeFilter != oldValue else { return }
            relist()
            if let searchQuery { search(searchQuery) }
        }
    }

    let home: URL
    @ObservationIgnored private var read: [FileBrowserEntry] = []
    @ObservationIgnored private var showsHidden = false
    @ObservationIgnored private var ignore = FileSearchIgnoreList(patterns: FileSearchIgnoreList.defaults)
    /// A read that finishes after the user has moved on must not replace the folder they moved to.
    @ObservationIgnored private var generation = 0
    /// The names below `directory`, built on the first keystroke and dropped the moment it changes.
    @ObservationIgnored private var index: FileTreeIndex?
    @ObservationIgnored private var indexTask: Task<FileTreeIndex, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    nonisolated static let searchLimit = 200
    /// One keystroke's pause; the folder's own matches cover it, so typing never waits on a walk.
    private static let debounce: Duration = .milliseconds(80)

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
        directory = self.home
    }

    var displayPath: String { FileBrowserPath.display(directory, home: home) }
    /// The field's text for the folder on screen: `~/Development/`.
    var pathText: String { FileBrowserPath.typed(directory, home: home) }
    var canGoUp: Bool { directory.path != "/" }

    func apply(ignorePatterns: [String], showsHidden: Bool) {
        let ignore = FileSearchIgnoreList(patterns: FileSearchIgnoreList.defaults + ignorePatterns)
        guard ignore != self.ignore || showsHidden != self.showsHidden else { return }
        self.ignore = ignore
        self.showsHidden = showsHidden
        dropIndex()
        relist()
        if let searchQuery { search(searchQuery) }
    }

    /// Typed text: a path walks, and what is left after it searches the folder it reached.
    @discardableResult
    func type(_ text: String) -> String {
        let location = FileBrowserPath.walk(
            text, from: directory, home: home, isDirectory: Self.isDirectory)
        if location.directory != directory {
            open(location.directory)
        } else if !location.filter.isEmpty {
            revealedName = nil
        }
        filter = location.filter
        search(location.filter)
        return location.filter
    }

    func open(_ folder: URL, revealing name: String? = nil) {
        releaseSearch()
        filter = ""
        directory = folder.standardizedFileURL
        revealedName = name
        state = .loading
        generation &+= 1
        let current = generation
        let target = directory
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Self.list(target) }.value
            guard current == generation else { return }
            switch outcome {
            case .success(let entries):
                read = entries
                state = .ready
            case .failure(let failure):
                read = []
                state = failure
            }
            relist()
        }
    }

    /// Re-reads the folder on screen, for a summon after files changed under it; nothing else resets.
    func reload() {
        generation &+= 1
        let current = generation
        let target = directory
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Self.list(target) }.value
            guard current == generation, case .success(let entries) = outcome, entries != read else { return }
            read = entries
            relist()
        }
    }

    func goUp() {
        guard canGoUp else { return }
        open(FileBrowserPath.parent(of: directory), revealing: directory.lastPathComponent)
    }

    /// Back to the user's home, as a fresh summon of the browser starts.
    func reset() {
        showsExcluded = false
        typeFilter = .all
        open(home)
    }

    /// Hiding the palette or leaving the browser frees every name read below the folder.
    func releaseSearch() {
        searchTask?.cancel()
        searchTask = nil
        dropIndex()
        isSearching = false
        guard searchQuery != nil else { return }
        searchQuery = nil
        publish(listingRows)
    }

    private func dropIndex() {
        indexTask?.cancel()
        indexTask = nil
        guard index != nil else { return }
        index = nil
        // Freed names stay in malloc's zones otherwise, and the app's footprint would never come back.
        malloc_zone_pressure_relief(nil, 0)
    }

    private var listingRows: [FileSearchResult] {
        listing.entries.map { FileSearchResult(url: $0.url, isDirectory: $0.isDirectory, homeDirectory: home) }
    }

    private func relist() {
        listing = FileBrowserListing(
            read, filter: "", showsHidden: showsHidden, showsExcluded: showsExcluded, ignore: ignore,
            type: typeFilter)
        if let searchQuery {
            if isSearching {
                publish(Self.rankFolder(listing.entries, searchQuery, type: typeFilter, home: home))
            }
        } else {
            publish(listingRows)
        }
    }

    private func publish(_ rows: [FileSearchResult]) {
        self.rows = rows
        rowsRevision &+= 1
    }

    private func search(_ query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            isSearching = false
            if searchQuery != nil {
                searchQuery = nil
                publish(listingRows)
            }
            return
        }
        searchQuery = query
        isSearching = true
        publish(Self.rankFolder(listing.entries, query, type: typeFilter, home: home))
        let folder = directory
        let home = home
        let ignore = ignore
        let type = typeFilter
        let walks = FileTreeIndexer.walks(folder, home: home)
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let tree = walks ? await treeIndex(for: folder) : nil
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                Self.results(query, in: folder, tree: tree, type: type, home: home, ignore: ignore)
            }.value
            guard !Task.isCancelled, searchQuery == query, directory == folder else { return }
            isSearching = false
            publish(results)
        }
    }

    /// Read once per folder visit, then every keystroke ranks what is already in memory.
    private func treeIndex(for folder: URL) async -> FileTreeIndex {
        if let index, index.root == folder.path { return index }
        let task =
            indexTask
            ?? {
                let home = home
                let showsHidden = showsHidden
                let ignore = ignore
                let task = Task.detached(priority: .userInitiated) {
                    FileTreeIndexer.build(root: folder, home: home, showsHidden: showsHidden, ignore: ignore)
                }
                indexTask = task
                return task
            }()
        let built = await task.value
        if directory == folder, indexTask == task {
            index = built
            indexTask = nil
        }
        return built
    }

    /// The folder's own items, instantly, while the subtree is still being asked.
    /// The folder's own items, instantly, while the subtree is still being asked.
    private static func rankFolder(
        _ entries: [FileBrowserEntry], _ text: String, type: FileSearchFilter, home: URL
    ) -> [FileSearchResult] {
        let query = FileQuery(text)
        let folded = FileQuery.Folded(query)
        var types: [String: Bool] = [:]
        let scored: [(entry: FileBrowserEntry, score: Int)] = entries.compactMap { entry in
            guard query.admits(name: entry.name, isDirectory: entry.isDirectory),
                type.accepts(name: entry.name, isDirectory: entry.isDirectory, cache: &types),
                let score = FileQuery.score(folded, entry.name)
            else { return nil }
            return (entry, score)
        }
        let ranked = scored.sorted { left, right in
            let leftBand = FileNameScore.band(left.score)
            let rightBand = FileNameScore.band(right.score)
            if leftBand != rightBand { return leftBand > rightBand }
            if left.score != right.score { return left.score > right.score }
            return left.entry.name.localizedStandardCompare(right.entry.name) == .orderedAscending
        }
        return ranked.prefix(searchLimit).map { item in
            FileSearchResult(url: item.entry.url, isDirectory: item.entry.isDirectory, homeDirectory: home)
        }
    }

    /// The index answers what it read; Spotlight answers for a tree too wide, or one it cut short.
    private nonisolated static func results(
        _ text: String, in folder: URL, tree: FileTreeIndex?, type: FileSearchFilter, home: URL,
        ignore: FileSearchIgnoreList
    ) -> [FileSearchResult] {
        let query = FileQuery(text)
        let folded = FileQuery.Folded(query)
        var types: [String: Bool] = [:]
        var found: [(result: FileSearchResult, score: Int)] = []
        if let tree {
            let hits = tree.search(query, limit: searchLimit) { name, isDirectory in
                type.accepts(name: name, isDirectory: isDirectory, cache: &types)
            }
            found = hits.map { index in
                let result = FileSearchResult(
                    url: URL(fileURLWithPath: tree.path(at: index)), isDirectory: tree.isDirectory(at: index),
                    homeDirectory: home)
                // A hit the scorer cannot place came from the typo pass, and ranks as one.
                return (result, FileQuery.score(folded, result.name) ?? FileQuery.typoScore(for: result.name))
            }
        }
        if tree?.isTruncated ?? true {
            let seen = Set(found.map(\.result.id))
            let spotlight =
                (try? FileSearchService.subtree(
                    query, in: folder, filter: type, ignore: ignore, homeDirectory: home)) ?? []
            for result in spotlight where !seen.contains(result.id) {
                guard query.admits(name: result.name, isDirectory: result.isDirectory),
                    let score = FileQuery.score(folded, result.name)
                else { continue }
                found.append((result, score))
            }
        }
        let base = folder.standardizedFileURL.pathComponents.count
        return
            found
            .map { ($0.result, $0.score, $0.result.url.pathComponents.count - base) }
            .sorted { left, right in
                let leftBand = FileNameScore.band(left.1)
                let rightBand = FileNameScore.band(right.1)
                if leftBand != rightBand { return leftBand > rightBand }
                if left.2 != right.2 { return left.2 < right.2 }
                if left.1 != right.1 { return left.1 > right.1 }
                return left.0.name.localizedStandardCompare(right.0.name) == .orderedAscending
            }
            .prefix(searchLimit)
            .map(\.0)
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    /// One read of one folder, keyed for the three facts a row needs and nothing that costs a walk.
    private nonisolated static func list(_ folder: URL) -> Result<[FileBrowserEntry], State> {
        Signposts.interval("FileBrowserSession.list") {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: keys, options: [])
                return .success(
                    urls.map { url in
                        let values = try? url.resourceValues(forKeys: Set(keys))
                        let isPackage = values?.isPackage ?? false
                        return FileBrowserEntry(
                            url: url, name: url.lastPathComponent,
                            isDirectory: (values?.isDirectory ?? false) && !isPackage,
                            isHidden: values?.isHidden ?? url.lastPathComponent.hasPrefix("."))
                    })
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return .failure(.missing)
            } catch {
                return .failure(.denied)
            }
        }
    }
}

extension FileBrowserSession.State: Error {}
