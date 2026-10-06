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

    /// `~/Development` rather than `/Users/me/Development`, as the field is typed.
    static func display(_ directory: URL, home: URL) -> String {
        let path = directory.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}
