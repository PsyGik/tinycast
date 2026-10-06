import Foundation

/// Reads every name under one folder into a `FileTreeIndex`, within a size and time budget.
enum FileTreeIndexer {
    /// A wide subtree is Spotlight's to answer; reading it would cost the budget and find no better.
    private static let timeBudget: Duration = .seconds(1)

    /// Home, the root and anything above home hold everything; only Spotlight searches those.
    static func walks(_ root: URL, home: URL) -> Bool {
        let path = root.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        return path != "/" && path != homePath && !homePath.hasPrefix(path + "/")
    }

    /// Folders macOS guards: entered from above they would prompt with no step taken by the user.
    static func protectedFolders(home: URL) -> Set<String> {
        let home = home.standardizedFileURL
        return Set(
            ["Desktop", "Documents", "Downloads", "Library", "Library/Mobile Documents"].map {
                home.appending(path: $0).path
            })
    }

    nonisolated static func build(
        root: URL, home: URL, showsHidden: Bool, ignore: FileSearchIgnoreList
    ) -> FileTreeIndex {
        Signposts.interval("FileTreeIndexer.build") {
            let rootPath = root.standardizedFileURL.path
            var index = FileTreeIndex(root: rootPath)
            let protected = protectedFolders(home: home).filter { !rootPath.hasPrefix($0) }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
            let deadline = ContinuousClock.now.advanced(by: timeBudget)
            // Folders waiting to be read, by index: a queued `URL` keeps its cached attributes alive.
            var queue: [Int32] = [-1]
            var head = 0
            while head < queue.count {
                let parent = queue[head]
                head += 1
                let folder = parent < 0 ? root : URL(fileURLWithPath: index.path(at: Int(parent)))
                if Task.isCancelled || ContinuousClock.now > deadline {
                    index.isTruncated = true
                    break
                }
                // Each read's URLs and cached attributes are autoreleased: drained per folder, not at the end.
                let full = autoreleasepool { () -> Bool in
                    guard
                        let urls = try? FileManager.default.contentsOfDirectory(
                            at: folder, includingPropertiesForKeys: keys, options: [])
                    else { return false }
                    for url in urls {
                        guard index.count < FileTreeIndex.capacity else { return true }
                        let values = try? url.resourceValues(forKeys: Set(keys))
                        let name = url.lastPathComponent
                        if !showsHidden, values?.isHidden ?? name.hasPrefix(".") { continue }
                        let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
                        if isFolder, FileBrowserListing.isExcluded(name, ignore: ignore) { continue }
                        let added = index.append(name: name, parent: parent, isDirectory: isFolder)
                        if isFolder, !protected.contains(url.standardizedFileURL.path) {
                            queue.append(added)
                        }
                    }
                    return false
                }
                if full {
                    index.isTruncated = true
                    return index
                }
                // Visited folders are never revisited, so the queue's head can be dropped as it goes.
                if head > 4_096 {
                    queue.removeFirst(head)
                    head = 0
                }
            }
            return index
        }
    }
}
