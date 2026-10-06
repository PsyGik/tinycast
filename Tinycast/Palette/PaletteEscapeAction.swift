import Foundation

/// Ordered like a bare backspace: a screen is only left once the search field is empty.
enum PaletteEscapeAction: Equatable {
    case clearMenuQuery
    case closeMenu
    case leaveArgumentField
    case clearQuery
    /// The launcher's chosen category, dropped back to All before the palette closes.
    case clearCategory
    /// Browse Files is a place reached from the launcher, so leaving it lands there, never closed.
    case returnToLauncher
    /// Browse Files keeps its path in the field; Escape clears only what was typed after it.
    case clearBrowseFilter
    case exitExtensionScreen
    case goBack
    case hidePalette

    static func resolve(
        menuOpen: Bool, menuQuery: String, argumentFocused: Bool, query: String, mode: PaletteMode,
        canGoBack: Bool, behavior: EscapeKeyBehavior, categoryChosen: Bool = false,
        browseFilter: String = ""
    ) -> Self {
        if menuOpen { return menu(query: menuQuery) }
        // An argument field is a step deeper than the query, so it is left before anything clears.
        if argumentFocused { return .leaveArgumentField }
        if mode == .browseFiles { return browseFilter.isEmpty ? .returnToLauncher : .clearBrowseFilter }
        if !query.isEmpty { return .clearQuery }
        if categoryChosen, mode == .launcher { return .clearCategory }
        guard behavior == .navigateBackOrClose else { return .hidePalette }
        // An extension pops its own navigation stack before the command is left.
        if mode == .extensionCommand { return .exitExtensionScreen }
        return canGoBack ? .goBack : .hidePalette
    }

    static func menu(query: String) -> Self {
        query.isEmpty ? .closeMenu : .clearMenuQuery
    }
}
