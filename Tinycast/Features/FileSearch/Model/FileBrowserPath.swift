import Foundation

/// Where typed text leaves the browser: the folder it walked to, and what is left to filter by.
struct FileBrowserLocation: Equatable, Sendable {
    var directory: URL
    var filter: String
}

enum FileBrowserPath {
    /// What turns the launcher into the browser: a home-relative or an absolute path.
    static func starts(_ text: String) -> Bool {
        text.hasPrefix("~") || text.hasPrefix("/")
    }

    /// `~/Dev/ti` walks to `~/Dev` and filters by `ti`; a segment that is no folder stops the walk.
    static func walk(
        _ text: String, from directory: URL, home: URL, isDirectory: (URL) -> Bool
    ) -> FileBrowserLocation {
        var base = directory.standardizedFileURL
        var rest = Substring(text)
        if rest.hasPrefix("~") {
            base = home.standardizedFileURL
            rest = rest.dropFirst()
            if rest.hasPrefix("/") { rest = rest.dropFirst() }
        } else if rest.hasPrefix("/") {
            base = URL(fileURLWithPath: "/")
            rest = rest.dropFirst()
        }
        var segments = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let last = segments.popLast() ?? ""
        for (index, segment) in segments.enumerated() {
            switch segment {
            case "", ".":
                continue
            case "..":
                base = parent(of: base)
            default:
                let next = base.appending(path: segment, directoryHint: .isDirectory)
                guard isDirectory(next) else {
                    let unwalked = segments[index...] + [last]
                    return FileBrowserLocation(directory: base, filter: unwalked.joined(separator: "/"))
                }
                base = next.standardizedFileURL
            }
        }
        if last == ".." { return FileBrowserLocation(directory: parent(of: base), filter: "") }
        return FileBrowserLocation(directory: base, filter: last)
    }

    /// The root is its own parent, as `cd ..` leaves it.
    static func parent(of directory: URL) -> URL {
        directory.path == "/" ? directory : directory.deletingLastPathComponent().standardizedFileURL
    }

    /// What the field reads for a folder: its path and a slash, so the next keystroke filters it.
    static func typed(_ directory: URL, home: URL) -> String {
        let shown = display(directory, home: home)
        return shown == "/" ? shown : shown + "/"
    }

    /// One segment of the header's path: a folder to jump to, or the `…` standing in for several.
    struct Crumb: Equatable, Sendable {
        let title: String
        /// Nil for the `…` that stands in for the folders a long path leaves out.
        let folder: URL?
    }

    /// `~ › Development › Swift › tinycast`, the middle folded into `…` past `kept` trailing folders.
    static func crumbs(_ directory: URL, home: URL, kept: Int = 3) -> [Crumb] {
        let path = directory.standardizedFileURL
        let homePath = home.standardizedFileURL
        let underHome = path.path == homePath.path || path.path.hasPrefix(homePath.path + "/")
        let root = underHome ? homePath : URL(fileURLWithPath: "/")
        var folders: [URL] = []
        var current = path
        while current.path != root.path, current.path != "/" {
            folders.insert(current, at: 0)
            current = parent(of: current)
        }
        var crumbs = [Crumb(title: underHome ? "~" : "/", folder: root)]
        if folders.count > kept + 1 {
            crumbs.append(Crumb(title: "…", folder: nil))
            folders = Array(folders.suffix(kept))
        }
        crumbs += folders.map { Crumb(title: $0.lastPathComponent, folder: $0) }
        return crumbs
    }

    /// The folders between `base` and an item below it, `Swift/tinycast`; nil for a direct child.
    static func between(_ base: URL?, and item: URL) -> String? {
        guard let base else { return nil }
        let parent = item.deletingLastPathComponent().standardizedFileURL.pathComponents
        let root = base.standardizedFileURL.pathComponents
        guard parent.count > root.count, Array(parent.prefix(root.count)) == root else { return nil }
        return parent.dropFirst(root.count).joined(separator: "/")
    }

    /// `~/Development` rather than `/Users/me/Development`, as the field is typed.
    static func display(_ directory: URL, home: URL) -> String {
        let path = directory.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}
