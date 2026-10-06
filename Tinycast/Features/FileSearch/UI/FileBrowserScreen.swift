import SwiftUI

/// Browse Files: one folder at a time, the File Search list and preview, ← and → to walk.
struct FileBrowserScreen: PaletteScreen {
    let session: FileBrowserSession
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    private var metrics: InterfaceMetrics { core.settings.interfaceSize.metrics }

    var rows: [FileSearchResult] { session.rows }

    private func result(at selection: Int) -> FileSearchResult? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// Going up lands on the folder just left, the way Finder's column view keeps your place.
    var landingSelection: Int {
        session.revealedName.flatMap { name in rows.firstIndex { $0.name == name } } ?? 0
    }

    var primaryActionTitle: String {
        result(at: vm.selection)?.isDirectory == true ? "Open Folder" : "Open File"
    }

    var footerContext: PaletteFooterContext? {
        PaletteFooterContext(title: session.displayPath, systemImage: "folder")
    }

    /// A folder is walked into here; macOS asks for a protected one only on this explicit step.
    func activate(at selection: Int) {
        guard let result = result(at: selection) else { return }
        if result.isDirectory {
            enter(result)
        } else {
            core.fileSearchCoordinator.open(result)
        }
    }

    func secondary(at selection: Int) -> Bool {
        guard let result = result(at: selection) else { return false }
        core.fileSearchCoordinator.showInFinder(result)
        return true
    }

    /// → opens the selected folder; ← goes up while the field is empty, else it moves the caret.
    func move(_ delta: Int, axis: PaletteAxis, from selection: Int) -> Int? {
        guard axis == .horizontal else { return nil }
        if delta > 0 {
            guard let result = result(at: selection), result.isDirectory else { return nil }
            enter(result)
            return 0
        }
        guard vm.query.isEmpty, session.canGoUp else { return nil }
        session.goUp()
        return selection
    }

    private func enter(_ folder: FileSearchResult) {
        vm.query = ""
        session.open(folder.url)
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard let result = result(at: selection) else { return false }
        switch shortcut {
        case .quickLook:
            vm.fileSearchQuickLook.toggle()
        case .copyPath:
            core.fileSearchCoordinator.copyPath(result)
        case .copyName:
            core.fileSearchCoordinator.copyName(result)
        default:
            return false
        }
        return true
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let result = result(at: selection) else { return nil }
        let coordinator = core.fileSearchCoordinator
        let settings = core.settings
        return PopoverMenuContent(
            header: result.name,
            items: [
                PopoverMenuItem(
                    title: result.isDirectory ? "Open Folder" : "Open File",
                    systemImage: result.isDirectory ? "folder" : "doc", shortcut: "↵"
                ) { activate(at: selection) },
                PopoverMenuItem(title: "Show in Finder", systemImage: "folder", shortcut: "⌘↵") {
                    coordinator.showInFinder(result)
                },
                PopoverMenuItem(title: "Quick Look", systemImage: "eye", shortcut: "⌘Y") {
                    vm.fileSearchQuickLook = true
                },
                PopoverMenuItem(
                    title: "Copy Path", systemImage: "doc.on.clipboard", startsSection: true,
                    shortcut: "⌃⌘C"
                ) { coordinator.copyPath(result) },
                PopoverMenuItem(title: "Copy Name", systemImage: "doc.on.clipboard", shortcut: "⌥⌘C") {
                    coordinator.copyName(result)
                },
                PopoverMenuItem(
                    title: settings.fileBrowserShowsHidden ? "Hide Hidden Files" : "Show Hidden Files",
                    systemImage: "eye.slash", startsSection: true
                ) { settings.fileBrowserShowsHidden.toggle() },
                PopoverMenuItem(
                    title: session.showsExcluded ? "Hide Excluded Folders" : "Show Excluded Folders",
                    systemImage: "folder.badge.minus"
                ) { session.showsExcluded.toggle() },
            ])
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        switch session.state {
        case .denied:
            EmptyResults(
                text: "Tinycast can’t open this folder. Allow it in System Settings › Privacy & "
                    + "Security › Files & Folders.")
        case .missing:
            EmptyResults(text: "This folder no longer exists")
        case .loading where rows.isEmpty:
            Color.clear
        default:
            if rows.isEmpty {
                EmptyResults(text: emptyText)
            } else {
                list(selection: selection, scroll: scroll)
            }
        }
    }

    private var emptyText: String {
        if !vm.query.isEmpty { return "Nothing in \(session.displayPath) matches" }
        let excluded = session.listing.excludedCount
        return excluded > 0 ? "Only excluded folders here — ⌘K to show them" : "This folder is empty"
    }

    /// The path heads the list, with what was set aside, so a missing folder is never a mystery.
    private var title: String {
        var parts = [session.displayPath]
        if session.listing.excludedCount > 0, !session.showsExcluded {
            parts.append("\(session.listing.excludedCount) excluded")
        }
        if session.listing.hiddenByLimit > 0 {
            parts.append("\(session.listing.hiddenByLimit) more — type to filter")
        }
        return parts.joined(separator: " · ")
    }

    private func list(selection: Int, scroll: ScrollIntent) -> some View {
        let selected = result(at: selection)
        return HStack(spacing: 0) {
            FileSearchList(
                title: title, results: rows, selectedID: selected?.id, scroll: scroll,
                browsing: true,
                onSelect: { result in vm.selection = rows.firstIndex(of: result) ?? 0 },
                onActivate: { result in
                    if let index = rows.firstIndex(of: result) { activate(at: index) }
                },
                onActions: { result in
                    if let index = rows.firstIndex(of: result) { vm.selection = index }
                    openActions()
                },
                onDropped: { core.paletteCoordinator.dragLanded() }
            )
            .frame(width: metrics.size.clipboardListWidth)
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(width: Theme.Size.hairline)
            FileSearchPreview(result: selected)
        }
        .overlay {
            if vm.fileSearchQuickLook, let selected {
                FileSearchQuickLook(result: selected) { vm.fileSearchQuickLook = false }
            }
        }
    }
}
