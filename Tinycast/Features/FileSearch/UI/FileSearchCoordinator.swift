import AppKit

@MainActor
final class FileSearchCoordinator {
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let session: FileSearchSession
    private let indexer: FileIndexer
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private let windowController: PaletteWindowController
    private var sharePicker: NSSharingServicePicker?
    private unowned let core: AppCore

    init(
        settings: AppSettings, appIndex: AppIndex, session: FileSearchSession,
        indexer: FileIndexer, palette: PaletteState, paletteCoordinator: PaletteCoordinator,
        windowController: PaletteWindowController, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.session = session
        self.indexer = indexer
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.windowController = windowController
        self.core = core
        indexer.onIndexChanged = { [weak session] in session?.refresh() }
        indexer.onRecentChanged = { [weak session] in session?.refreshRecent() }
    }

    func applyEnabled() {
        appIndex.setCommandsVisible([.searchFiles, .browseFiles], settings.fileSearchEnabled)
        indexer.setEnabled(settings.fileSearchEnabled)
        guard !settings.fileSearchEnabled else { return }
        session.cancel()
        if palette.mode == .fileSearch { palette.prepare(mode: .launcher) }
    }

    func applyPolicy() {
        let policy = FileSearchPolicy(
            scopes: settings.fileSearchScopes,
            ignorePatterns: settings.fileSearchEffectiveIgnorePatterns,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        indexer.apply(policy)
        session.contentOperation = nil
        if settings.fileSearchIncludesContent {
            session.contentOperation = { query, filter in
                await Task.detached(priority: .userInitiated) {
                    FileContentSearch.search(query, filter: filter, policy: policy)
                }.value
            }
        }
        core.fileBrowser.apply(
            ignorePatterns: settings.fileSearchEffectiveIgnorePatterns,
            showsHidden: settings.fileBrowserShowsHidden)
    }

    var showsFilesInLauncher: Bool {
        settings.fileSearchEnabled && settings.fileSearchShowInLauncher
    }

    /// Borrows the screen's session, so Search Files then opens on the request already answered.
    func searchFromLauncher(_ query: String) {
        guard showsFilesInLauncher, FileSearchQuery.answersLauncher(query) else {
            session.cancel()
            return
        }
        session.search(query)
    }

    /// Checks the switch before reading the session, so with it off the launcher observes nothing.
    func launcherFiles(for query: String) -> [FileSearchResult] {
        guard showsFilesInLauncher, FileSearchQuery.answersLauncher(query) else { return [] }
        return Array(session.results.prefix(FileSearchQuery.launcherLimit))
    }

    func applyLauncherFiles() {
        guard palette.mode == .launcher else { return }
        searchFromLauncher(palette.query)
    }

    func rebuildIndex() {
        indexer.rebuild()
    }

    func openFullDiskAccessSettings() {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Permissions.openFullDiskAccessSettings()
    }

    /// `query` is the fallback row's: the screen opens already narrowed to what was typed.
    func show(query: String = "") {
        guard settings.fileSearchEnabled else { return }
        indexer.refreshAccess()
        paletteCoordinator.togglePalette(mode: .fileSearch, seeding: query.isEmpty ? nil : query)
    }

    /// Browse Files: a fresh summon starts at home, as a new Search Files starts blank.
    func browse() {
        guard settings.fileSearchEnabled else { return }
        core.fileBrowser.reset()
        paletteCoordinator.togglePalette(mode: .browseFiles, seeding: core.fileBrowser.pathText)
    }

    /// `~` or `/` typed into the launcher: the launcher stays beneath, so Escape walks back to it.
    func claimsLauncherQuery(_ query: String) -> Bool {
        settings.fileSearchEnabled && settings.fileBrowserFromLauncher && FileBrowserPath.starts(query)
    }

    /// The typed text stays in the field: it is the path, and what follows it is the filter.
    func browse(fromLauncher query: String) {
        core.fileBrowser.reset()
        core.fileBrowser.type(query)
        paletteCoordinator.navigate(to: .browseFiles)
        palette.query = query
    }

    func open(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    result.url, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                await core.showNotice(
                    title: String(localized: "Couldn’t Open \(result.name)"),
                    message: error.localizedDescription,
                    symbol: result.isDirectory ? "folder" : "doc", tone: .danger)
            }
        }
    }

    /// The system Quick Look window over every listed row, opened on `result`; the palette steps aside.
    func openInQuickLook(_ result: FileSearchResult, among rows: [FileSearchResult]) {
        let returnTo = paletteCoordinator.targetApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        let index = rows.firstIndex(of: result) ?? 0
        core.systemQuickLook.show(rows.map(\.url), at: index, returningTo: returnTo)
    }

    /// From a menu, which knows the row: the session's list around it when the row is in it.
    func openInQuickLook(_ result: FileSearchResult) {
        openInQuickLook(result, among: session.results.contains(result) ? session.results : [result])
    }

    func showInFinder(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(result.url)
    }

    /// macOS's own share sheet, anchored to the palette's trailing edge so the row stays beside it.
    func share(_ result: FileSearchResult) {
        guard let provider = NSItemProvider(contentsOf: result.url),
            let anchor = paletteCoordinator.anchorView
        else { return }
        let picker = NSSharingServicePicker(items: [provider])
        sharePicker = picker
        picker.show(
            relativeTo: CGRect(
                x: anchor.bounds.maxX, y: anchor.bounds.midY, width: 0, height: 0),
            of: anchor, preferredEdge: .maxX)
    }

    func showInfo(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Task {
            guard await !AppLauncher.showInfoInFinder(result.url) else { return }
            await core.showNotice(
                title: "Couldn’t Open Get Info",
                message: "Allow Tinycast to control Finder in System Settings › Privacy & Security "
                    + "› Automation, then try again.",
                symbol: "info.circle", tone: .danger)
        }
    }

    /// Opens the Quicklinks editor prefilled, so the user names and saves it there.
    func saveAsQuicklink(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.quicklinkCoordinator.editQuicklink(
            Quicklink(name: result.name, link: result.url.absoluteString))
    }

    func copyPath(_ result: FileSearchResult) {
        Paster.copyPlainText(result.id)
        core.showMessage(String(localized: "Copied path"))
    }

    func copyName(_ result: FileSearchResult) {
        Paster.copyPlainText(result.name)
        core.showMessage(String(localized: "Copied name"))
    }

    /// The file itself rather than its path, so Finder and Mail paste a copy of it.
    func copyFile(_ result: FileSearchResult) {
        PasteboardFiles.write(result.url, to: .general)
        core.showMessage(String(localized: "Copied file"))
    }

    /// Into whichever app the palette was summoned over, which is what the row's title names.
    func pasteFile(_ result: FileSearchResult) {
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.pasteFile(result.url, previousApp: previous)
    }

    func trash(_ result: FileSearchResult) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.trashItem(at: result.url, resultingItemURL: nil)
                }.value
                session.remove(result)
                core.showMessage(String(localized: "Moved to Trash"))
            } catch {
                await core.showNotice(
                    title: String(localized: "Couldn’t Move \(result.name) to Trash"),
                    message: error.localizedDescription,
                    symbol: "trash", tone: .danger)
            }
        }
    }
}
