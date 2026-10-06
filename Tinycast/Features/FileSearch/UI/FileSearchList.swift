import SwiftUI

struct FileSearchList: View {

    @Environment(\.metrics) private var metrics
    let title: String
    let results: [FileSearchResult]
    let selectedID: FileSearchResult.ID?
    let scroll: ScrollIntent
    /// Browsing one folder: every row shares the parent, and a folder is somewhere to go next.
    var browsing = false
    /// The folder being browsed; a deeper result names the folders between it and the match.
    var base: URL?
    let onSelect: (FileSearchResult) -> Void
    let onActivate: (FileSearchResult) -> Void
    let onActions: (FileSearchResult) -> Void
    let onDropped: () -> Void

    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == results.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    SectionHeader(title: title, isFirst: true, style: .palette)
                    ForEach(results) { result in
                        FileSearchRow(
                            result: result, selected: result.id == selectedID, browsing: browsing,
                            base: base)
                            .selectionFrame(result.id == selectedID)
                            .contentShape(Rectangle())
                            .onRowClick(
                                select: { onSelect(result) }, activate: { onActivate(result) },
                                drag: drag(for: result)
                            )
                            .onRightClick { onActions(result) }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: firstRowSelected, proxy: proxy)
        }
        .onDisappear { IconCache.purgeFitted() }
    }

    /// The row's own fitted tile, which is warm by the time a pointer can reach it.
    private func drag(for result: FileSearchResult) -> RowDrag {
        RowDrag(
            item: { .file(result.url, image: IconCache.cachedFitted(forFile: result.id)) },
            dropped: onDropped)
    }
}

private struct FileSearchRow: View {

    @Environment(\.metrics) private var metrics
    let result: FileSearchResult
    let selected: Bool
    let browsing: Bool
    let base: URL?
    @State private var image: NSImage?
    @State private var hovered = false

    init(result: FileSearchResult, selected: Bool, browsing: Bool, base: URL?) {
        self.result = result
        self.selected = selected
        self.browsing = browsing
        self.base = base
        _image = State(initialValue: IconCache.cachedFitted(forFile: result.id))
    }

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    /// A folder is named by where it sits: half the hits are some `src` or `Tinycast`.
    private var label: Text {
        if browsing {
            guard let between = FileBrowserPath.between(base, and: result.url) else { return Text(result.name) }
            return Text("\(Text("\(between)/").foregroundStyle(.secondary))\(result.name)")
        }
        guard result.isDirectory, !result.parentName.isEmpty else { return Text(result.name) }
        let parent = Text("\(result.parentName)/").foregroundStyle(.secondary)
        return Text("\(parent)\(result.name)")
    }

    var body: some View {
        HStack(spacing: metrics.spacing.xl) {
            Group {
                if let image {
                    Image(nsImage: image).resizable()
                } else {
                    RoundedRectangle(cornerRadius: metrics.radius.thumbnail, style: .continuous)
                        .fill(Theme.Colors.iconPlaceholder)
                }
            }
            .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            // The column is too narrow for a path beside the name; the preview states it instead.
            label
                .font(metrics.typography.paletteRowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if browsing, result.isDirectory {
                Image(systemName: "chevron.right")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.paletteListRow, style: .continuous)
                .fill(fill)
        )
        .armedHover($hovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.name)
        .accessibilityValue(result.parentPath)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: IconRequest(result.id)) {
            if let warm = IconCache.cachedFitted(forFile: result.id) {
                image = warm
                return
            }
            image = await IconCache.loadFittedAsync(forFile: result.id)
        }
    }
}
