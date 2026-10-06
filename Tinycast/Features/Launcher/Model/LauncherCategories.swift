import Foundation

/// The rule that turns the categories switch off once nothing it governs is left on.
enum LauncherCategoryVisibility {
    static func hidesAll(_ hidden: [String], of all: [String]) -> Bool {
        !all.isEmpty && Set(all).isSubset(of: hidden)
    }
}

/// What a chosen category leads with: the entries in it the user reached for lately, newest first.
enum LauncherCategoryRecents {
    static let limit = 5
    /// Older than this, a use is habit rather than recent, and the regular order already shows it.
    static let window: TimeInterval = 30 * 86_400

    static func select<Item>(_ items: [Item], lastUsed: (Item) -> Date?, now: Date) -> [Item] {
        let start = now.addingTimeInterval(-window)
        return items.enumerated()
            .compactMap { position, item -> (Item, Date, Int)? in
                guard let used = lastUsed(item), used >= start else { return nil }
                return (item, used, position)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .prefix(limit)
            .map(\.0)
    }
}
