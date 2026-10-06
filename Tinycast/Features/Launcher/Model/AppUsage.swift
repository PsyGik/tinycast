import Foundation

/// What Spotlight recorded about one app's use, for launches from anywhere — not just Tinycast.
struct AppUsage: Sendable, Equatable {
    /// One stamp per local day the app was opened, as `kMDItemUsedDates` keeps them.
    var usedDays: [Date]
    var lastUsed: Date
}

/// How the Frequently Used section orders its apps.
enum AppUsageOrder: String, CaseIterable, Identifiable, Sendable {
    case frequency
    case recency

    var id: Self { self }

    var title: String {
        switch self {
        case .frequency: "Most days used"
        case .recency: "Most recently used"
        }
    }
}

/// How far back an app's use counts, for the section and for ranking alike.
enum AppUsageWindow: Int, CaseIterable, Identifiable, Sendable {
    case week = 7
    case month = 30
    case quarter = 90

    static let longest = Self.quarter

    var id: Self { self }
    var title: String { "Last \(rawValue) days" }
    var interval: TimeInterval { Double(rawValue) * 86_400 }
}

/// How many apps the Frequently Used section lists; `off` keeps usage for ranking alone.
enum AppUsageSectionSize: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case three = 3
    case five = 5
    case eight = 8

    var id: Self { self }
    var title: String { self == .off ? "Off" : "\(rawValue) apps" }
}

enum AppUsageRanking {
    /// Distinct days used inside the window; an app whose last use predates it scores nothing.
    static func frequency(_ usage: AppUsage, window: AppUsageWindow, now: Date) -> Double {
        let start = now.addingTimeInterval(-window.interval)
        guard usage.lastUsed >= start else { return 0 }
        // A launch Spotlight has stamped but not yet folded into its day list still counts once.
        return Double(max(Set(usage.usedDays.filter { $0 >= start }).count, 1))
    }

    /// The apps to list, best first: ties on days fall to the latest use, then to `items` order.
    static func top<Item>(
        _ items: [Item], usage: (Item) -> AppUsage?, order: AppUsageOrder, window: AppUsageWindow,
        now: Date, limit: Int
    ) -> [Item] {
        guard limit > 0 else { return [] }
        let scored = items.enumerated().compactMap { position, item -> (Item, Double, Date, Int)? in
            guard let usage = usage(item) else { return nil }
            let days = frequency(usage, window: window, now: now)
            guard days > 0 else { return nil }
            return (item, days, usage.lastUsed, position)
        }
        return
            scored
            .sorted { a, b in
                if order == .frequency, a.1 != b.1 { return a.1 > b.1 }
                if a.2 != b.2 { return a.2 > b.2 }
                return a.3 < b.3
            }
            .prefix(limit)
            .map(\.0)
    }
}
