import Foundation

/// The folder the browser shows: one directory read at a time, never a walk of what is below it.
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
    /// The folder just left, so going up lands on it rather than on the first row.
    private(set) var revealedName: String?
    var showsExcluded = false {
        didSet { if showsExcluded != oldValue { relist() } }
    }

    let home: URL
    @ObservationIgnored private var read: [FileBrowserEntry] = []
    @ObservationIgnored private var filter = ""
    @ObservationIgnored private var showsHidden = false
    @ObservationIgnored private var ignore = FileSearchIgnoreList(patterns: FileSearchIgnoreList.defaults)
    /// A read that finishes after the user has moved on must not replace the folder they moved to.
    @ObservationIgnored private var generation = 0

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
        directory = self.home
    }

    var rows: [FileSearchResult] {
        listing.entries.map { FileSearchResult(url: $0.url, isDirectory: $0.isDirectory, homeDirectory: home) }
    }

    var displayPath: String { FileBrowserPath.display(directory, home: home) }
    var canGoUp: Bool { directory.path != "/" }

    func apply(ignorePatterns: [String], showsHidden: Bool) {
        let ignore = FileSearchIgnoreList(patterns: FileSearchIgnoreList.defaults + ignorePatterns)
        guard ignore != self.ignore || showsHidden != self.showsHidden else { return }
        self.ignore = ignore
        self.showsHidden = showsHidden
        relist()
    }

    /// Typed text: a path walks, anything else filters the folder on screen.
    func type(_ text: String) -> String {
        let location = FileBrowserPath.walk(
            text, from: directory, home: home, isDirectory: Self.isDirectory)
        if location.directory != directory {
            open(location.directory)
        } else {
            revealedName = nil
        }
        filter = location.filter
        relist()
        return location.filter
    }

    func open(_ folder: URL, revealing name: String? = nil) {
        directory = folder.standardizedFileURL
        revealedName = name
        filter = ""
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

    func goUp() {
        guard canGoUp else { return }
        open(FileBrowserPath.parent(of: directory), revealing: directory.lastPathComponent)
    }

    /// Back to the user's home, as a fresh summon of the browser starts.
    func reset() {
        showsExcluded = false
        open(home)
    }

    private func relist() {
        listing = FileBrowserListing(
            read, filter: filter, showsHidden: showsHidden, showsExcluded: showsExcluded, ignore: ignore)
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
