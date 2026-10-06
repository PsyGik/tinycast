import CoreServices
import Foundation

/// Spotlight's record of which apps the user opens, read on demand and never stored by Tinycast.
@MainActor
@Observable
final class AppUsageStore {
    /// Keyed by standardized bundle path, which is how `AppEntry.url` names an app.
    private(set) var usage: [String: AppUsage] = [:]
    /// Part of `AppIndex`'s cache keys, so a refresh re-orders an open launcher.
    private(set) var revision = 0

    /// Spotlight stamps a launch within seconds, but a section the user is reading must not churn.
    static let refreshInterval: TimeInterval = 10 * 60

    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    func usage(forAppAt url: URL) -> AppUsage? {
        usage[url.standardizedFileURL.path]
    }

    /// Re-reads when the last read is older than `refreshInterval`, or `force` asks for it now.
    func refresh(force: Bool = false) {
        guard refreshTask == nil else { return }
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < Self.refreshInterval {
            return
        }
        refreshTask = Task { [weak self] in
            let read = await Task.detached(priority: .utility) {
                Self.read(within: AppUsageWindow.longest)
            }.value
            guard let self else { return }
            refreshTask = nil
            refreshedAt = Date()
            guard let read, read != usage else { return }
            usage = read
            revision &+= 1
        }
    }

    /// Switching the feature off forgets the snapshot, so nothing lingers in memory unused.
    func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshedAt = nil
        guard !usage.isEmpty else { return }
        usage = [:]
        revision &+= 1
    }

    /// One synchronous query over every app bundle used inside the window; nil when Spotlight fails.
    private nonisolated static func read(within window: AppUsageWindow) -> [String: AppUsage]? {
        Signposts.interval("AppUsageStore.read") { () -> [String: AppUsage]? in
            let expression =
                "kMDItemContentType == \"com.apple.application-bundle\""
                + " && kMDItemLastUsedDate >= $time.now(-\(Int(window.interval)))"
            guard let query = MDQueryCreate(nil, expression as CFString, nil, nil) else { return nil }
            MDQuerySetMaxCount(query, resultLimit)
            guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
            var read: [String: AppUsage] = [:]
            for index in 0..<MDQueryGetResultCount(query) {
                guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
                let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                guard
                    let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                    let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                else { continue }
                let days = MDItemCopyAttribute(item, usedDatesAttribute as CFString) as? [Date] ?? []
                let key = URL(fileURLWithPath: path).standardizedFileURL.path
                read[key] = AppUsage(usedDays: days, lastUsed: lastUsed)
            }
            return read
        }
    }

    /// Spotlight carries the attribute but the SDK exports no constant for it.
    private nonisolated static let usedDatesAttribute = "kMDItemUsedDates"

    /// Far above what anyone opens in 90 days; it only bounds a pathological index.
    private nonisolated static let resultLimit = 1_000
}
