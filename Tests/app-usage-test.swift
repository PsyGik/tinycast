import Foundation

@main
struct AppUsageTest {
    static func main() {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func day(_ ago: Double) -> Date { now.addingTimeInterval(-ago * 86_400) }
        func usage(_ days: [Double], last: Double) -> AppUsage {
            AppUsage(usedDays: days.map(day), lastUsed: day(last))
        }

        let daily = usage([1, 2, 3, 10, 40], last: 0.1)
        check(
            "frequency counts the distinct days inside the window",
            AppUsageRanking.frequency(daily, window: .month, now: now) == 4)
        check(
            "a wider window counts older days",
            AppUsageRanking.frequency(daily, window: .quarter, now: now) == 5)
        check(
            "a repeated day stamp counts once",
            AppUsageRanking.frequency(usage([2, 2, 2], last: 2), window: .week, now: now) == 1)
        check(
            "a launch Spotlight has not folded into its day list still counts once",
            AppUsageRanking.frequency(usage([], last: 0.5), window: .week, now: now) == 1)
        check(
            "an app last used before the window scores nothing, whatever its old days",
            AppUsageRanking.frequency(usage([20, 21, 22], last: 20), window: .week, now: now) == 0)

        struct App { let name: String; let usage: AppUsage? }
        let apps = [
            App(name: "Rare but recent", usage: usage([0.2], last: 0.2)),
            App(name: "Daily", usage: usage([1, 2, 3, 4, 5], last: 1)),
            App(name: "Never", usage: nil),
            App(name: "Weekly", usage: usage([3, 10], last: 3)),
            App(name: "Stale", usage: usage([50], last: 50)),
            App(name: "Daily twin", usage: usage([1, 2, 3, 4, 5], last: 0.5)),
        ]
        func top(_ order: AppUsageOrder, _ window: AppUsageWindow = .month, limit: Int = 8) -> [String] {
            AppUsageRanking.top(
                apps, usage: \.usage, order: order, window: window, now: now, limit: limit
            ).map(\.name)
        }

        check(
            "frequency lists most days first, a tie going to the latest use",
            top(.frequency) == ["Daily twin", "Daily", "Weekly", "Rare but recent"])
        check(
            "recency lists by last use alone",
            top(.recency) == ["Rare but recent", "Daily twin", "Daily", "Weekly"])
        check(
            "an app with no record or outside the window is never listed",
            !top(.frequency, .quarter).contains("Never")
                && !top(.frequency).contains("Stale") && top(.frequency, .quarter).contains("Stale"))
        check("the limit caps the list", top(.frequency, limit: 2) == ["Daily twin", "Daily"])
        check("a zero limit lists nothing", top(.frequency, limit: 0).isEmpty)
        check(
            "the section sizes are what Settings offers, off included",
            AppUsageSectionSize.allCases.map(\.rawValue) == [0, 3, 5, 8])

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
