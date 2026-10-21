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
        [], filter: "", showsHidden: false, showsExcluded: false, ignore: FileSearchIgnoreList(patterns: [], homeDirectory: URL(filePath: "/")))
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
    @ObservationIgnored private var ignore: FileSearchIgnoreList
    /// Search Files' disk index, which answers below a folder without a walk when it holds it.
    @ObservationIgnored private let fileIndex: FileIndex?
    /// A read that finishes after the user has moved on must not replace the folder they moved to.
    @ObservationIgnored private var generation = 0
    /// The names below `directory`, built on the first keystroke and dropped the moment it changes.
    @ObservationIgnored private var index: Source?
    @ObservationIgnored private var indexTask: Task<Source, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    nonisolated static let searchLimit = 200
    /// One keystroke's pause; the folder's own matches cover it, so typing never waits on a walk.
    private static let debounce: Duration = .milliseconds(80)

    /// Where a search below the folder finds its names.
    private enum Source: Sendable {
        case tree(FileTreeIndex)
        /// Too many names for a tree: the disk index searches the subtree itself.
        case wide
        case none
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, index: FileIndex? = nil) {
        self.home = home.standardizedFileURL
        directory = self.home
        fileIndex = index
        ignore = FileSearchIgnoreList(patterns: FileSearchIgnoreList.defaults, homeDirectory: home)
    }

    var displayPath: String { FileBrowserPath.display(directory, home: home) }
    /// The field's text for the folder on screen: `~/Development/`.
    var pathText: String { FileBrowserPath.typed(directory, home: home) }
    var canGoUp: Bool { directory.path != "/" }

    func apply(ignorePatterns: [String], showsHidden: Bool) {
        let ignore = FileSearchIgnoreList(patterns: ignorePatterns, homeDirectory: home)
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
        let showsHidden = showsHidden
        let fileIndex = fileIndex
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let source = await treeIndex(for: folder)
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                Self.results(
                    query, in: folder, source: source, fileIndex: fileIndex, type: type, home: home,
                    showsHidden: showsHidden, ignore: ignore)
            }.value
            guard !Task.isCancelled, searchQuery == query, directory == folder else { return }
            isSearching = false
            publish(results)
        }
    }

    /// Read once per folder visit, then every keystroke ranks what is already in memory.
    private func treeIndex(for folder: URL) async -> Source {
        if let index { return index }
        let task =
            indexTask
            ?? {
                let home = home
                let showsHidden = showsHidden
                let ignore = ignore
                let fileIndex = fileIndex
                let task = Task.detached(priority: .userInitiated) {
                    Self.source(
                        for: folder, fileIndex: fileIndex, home: home, showsHidden: showsHidden,
                        ignore: ignore)
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

    /// The disk index first, since it reads nothing; a walk only for a folder it does not hold.
    private nonisolated static func source(
        for folder: URL, fileIndex: FileIndex?, home: URL, showsHidden: Bool,
        ignore: FileSearchIgnoreList
    ) -> Source {
        let indexed = fileIndex?.tree(
            under: folder.path,
            include: { name, isDirectory in
                (showsHidden || !name.hasPrefix("."))
                    && !(isDirectory && FileBrowserListing.isExcluded(name, ignore: ignore))
            },
            descends: { !FileSearchPolicy.bundleExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
        switch indexed {
        case .tree(let tree): return .tree(tree)
        case .tooLarge: return .wide
        case .uncovered, nil:
            guard FileTreeIndexer.walks(folder, home: home) else { return .none }
            return .tree(FileTreeIndexer.build(root: folder, home: home, showsHidden: showsHidden, ignore: ignore))
        }
    }

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

    /// A tree answers what it holds; past its size the disk index searches the subtree itself.
    private nonisolated static func results(
        _ text: String, in folder: URL, source: Source, fileIndex: FileIndex?, type: FileSearchFilter,
        home: URL, showsHidden: Bool, ignore: FileSearchIgnoreList
    ) -> [FileSearchResult] {
        let query = FileQuery(text)
        let folded = FileQuery.Folded(query)
        var types: [String: Bool] = [:]
        var found: [(result: FileSearchResult, score: Int)] = []
        if case .tree(let tree) = source {
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
        if case .wide = source, let fileIndex, let prepared = FileSearchQuery.prepare(text) {
            let base = folder.path.split(separator: "/").count
            for result in fileIndex.search(prepared, filter: type, under: folder.path) {
                let below = result.url.path.split(separator: "/").dropFirst(base)
                // Hidden and excluded folders hold as much here as in a walk, which skips them.
                guard
                    !below.dropLast().contains(where: {
                        (!showsHidden && $0.hasPrefix("."))
                            || FileBrowserListing.isExcluded(String($0), ignore: ignore)
                    }),
                    showsHidden || !result.name.hasPrefix("."),
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
