import Foundation

/// One item of the folder on screen, as a single directory read reports it.
struct FileBrowserEntry: Equatable, Sendable {
    let url: URL
    let name: String
    /// False for a package: an `.app` or `.bundle` opens rather than being walked into.
    let isDirectory: Bool
    let isHidden: Bool
}

/// The folder on screen, ordered, filtered and with the heavy trees set aside.
struct FileBrowserListing: Equatable, Sendable {
    let entries: [FileBrowserEntry]
    /// Folders the ignore list sets aside, never listed unless asked for.
    let excludedCount: Int
    /// Past `limit`, a folder lists its head and asks for a filter rather than a scroll.
    let hiddenByLimit: Int

    /// Enough for any folder a person browses; more than this is a build tree, and a filter wins.
    static let limit = 2_000
    /// Trees nobody browses into by accident, on top of File Search's own ignore list.
    static let alwaysExcluded = [".git", ".venv", "__pycache__", ".next", ".cache", ".Trash"]

    /// Folders first, then the name as Finder sorts it; a filter keeps every term's match.
    init(
        _ read: [FileBrowserEntry], filter: String, showsHidden: Bool, showsExcluded: Bool,
        ignore: FileSearchIgnoreList
    ) {
        var kept: [FileBrowserEntry] = []
        var excluded = 0
        for entry in read where showsHidden || !entry.isHidden {
            if entry.isDirectory, Self.isExcluded(entry.name, ignore: ignore) {
                excluded += 1
                guard showsExcluded else { continue }
            }
            guard filter.isEmpty || FileSearchQuery.matches(filename: entry.name, query: filter) else {
                continue
            }
            kept.append(entry)
        }
        kept.sort { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        entries = Array(kept.prefix(Self.limit))
        excludedCount = excluded
        hiddenByLimit = max(0, kept.count - Self.limit)
    }

    /// By its own name only: a folder the user walked into on purpose lists everything inside it.
    static func isExcluded(_ name: String, ignore: FileSearchIgnoreList) -> Bool {
        alwaysExcluded.contains(name) || ignore.excludes(path: name)
    }
}
