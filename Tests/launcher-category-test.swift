import Foundation

@main
struct LauncherCategoryTest {
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
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        let items: [(String, Date?)] = [
            ("Old", ago(45)), ("Yesterday", ago(1)), ("Never", nil), ("Today", ago(0.1)),
            ("Week", ago(7)), ("Twin A", ago(3)), ("Twin B", ago(3)), ("Month", ago(29)),
        ]
        func recents(_ list: [(String, Date?)]) -> [String] {
            LauncherCategoryRecents.select(list, lastUsed: { $0.1 }, now: now).map(\.0)
        }

        check(
            "recently used is newest first, capped at five",
            recents(items) == ["Today", "Yesterday", "Twin A", "Twin B", "Week"])
        check(
            "a use older than the window, or none at all, is never recent",
            !recents(items).contains("Old") && !recents(items).contains("Never"))
        check(
            "a use inside the window still counts once the newer ones are gone",
            recents([("Month", ago(29)), ("Old", ago(31))]) == ["Month"])
        check(
            "equal stamps keep the category's own order",
            recents([("Twin B", ago(3)), ("Twin A", ago(3))]) == ["Twin B", "Twin A"])
        check("nothing used lists nothing", recents([("Never", nil)]).isEmpty)

        let all = ["application", "snippet", "quicklink"]
        check(
            "hiding every category switches the categories off",
            LauncherCategoryVisibility.hidesAll(["quicklink", "application", "snippet"], of: all))
        check(
            "one category left keeps them on",
            !LauncherCategoryVisibility.hidesAll(["application", "snippet"], of: all))
        check(
            "an unknown name left over in the list hides nothing extra",
            !LauncherCategoryVisibility.hidesAll(["application", "snippet", "retired"], of: all))
        check("no categories at all is not everything hidden", !LauncherCategoryVisibility.hidesAll([], of: []))

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
