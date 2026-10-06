import Foundation

@main
struct FileBrowserTest {
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

        let home = URL(fileURLWithPath: "/Users/test")
        let folders: Set<String> = [
            "/", "/Users", "/Users/test", "/Users/test/Development", "/Users/test/Development/web",
            "/Applications",
        ]
        func isDirectory(_ url: URL) -> Bool { folders.contains(url.standardizedFileURL.path) }
        func walk(_ text: String, from: String = "/Users/test") -> (String, String) {
            let location = FileBrowserPath.walk(
                text, from: URL(fileURLWithPath: from), home: home, isDirectory: isDirectory)
            return (location.directory.path, location.filter)
        }

        check("~ opens home with nothing to filter", walk("~") == ("/Users/test", ""))
        check("~/ is home too", walk("~/") == ("/Users/test", ""))
        check("/ opens the root", walk("/") == ("/", ""))
        check(
            "a completed segment walks, the rest filters",
            walk("~/Development/we") == ("/Users/test/Development", "we"))
        check(
            "a trailing slash enters the folder",
            walk("~/Development/web/") == ("/Users/test/Development/web", ""))
        check("an absolute path walks from the root", walk("/Applications/Sa") == ("/Applications", "Sa"))
        check(
            "a segment that is no folder stops the walk and stays in the filter",
            walk("~/Nope/x") == ("/Users/test", "Nope/x"))
        check(
            "plain text filters the folder on screen",
            walk("read", from: "/Users/test/Development") == ("/Users/test/Development", "read"))
        check(
            "a relative path walks from the folder on screen",
            walk("web/src", from: "/Users/test/Development") == ("/Users/test/Development/web", "src"))
        check(".. goes up", walk("..", from: "/Users/test/Development") == ("/Users/test", ""))
        check("../ goes up and keeps walking", walk("../../Development/", from: "/Users/test/Development/web")
            == ("/Users/test/Development", ""))
        check("the root is its own parent", walk("..", from: "/") == ("/", ""))
        check("only ~ and / start a path", FileBrowserPath.starts("~/x") && FileBrowserPath.starts("/")
            && !FileBrowserPath.starts("safari"))
        check(
            "home reads as ~, a folder in it as ~/…, anywhere else as itself",
            FileBrowserPath.display(home, home: home) == "~"
                && FileBrowserPath.display(home.appending(path: "Development"), home: home) == "~/Development"
                && FileBrowserPath.display(URL(fileURLWithPath: "/Applications"), home: home) == "/Applications")

        func entry(_ name: String, folder: Bool = false, hidden: Bool? = nil) -> FileBrowserEntry {
            FileBrowserEntry(
                url: home.appending(path: name), name: name, isDirectory: folder,
                isHidden: hidden ?? name.hasPrefix("."))
        }
        let read = [
            entry("zeta.txt"), entry("Alpha", folder: true), entry("node_modules", folder: true),
            entry("README.md"), entry(".git", folder: true), entry(".zshrc"), entry("dist", folder: true),
            entry("Item 10.txt"), entry("Item 2.txt"), entry("beta", folder: true),
        ]
        let ignore = FileSearchIgnoreList(patterns: FileSearchIgnoreList.defaults + ["*.log"])
        func names(
            filter: String = "", hidden: Bool = false, excluded: Bool = false, _ entries: [FileBrowserEntry]? = nil
        ) -> [String] {
            FileBrowserListing(
                entries ?? read, filter: filter, showsHidden: hidden, showsExcluded: excluded, ignore: ignore
            ).entries.map(\.name)
        }

        check(
            "folders first, then files, each as Finder sorts names",
            names() == ["Alpha", "beta", "Item 2.txt", "Item 10.txt", "README.md", "zeta.txt"])
        let listing = FileBrowserListing(
            read, filter: "", showsHidden: false, showsExcluded: false, ignore: ignore)
        check("excluded folders are counted, not listed", listing.excludedCount == 2)
        check(
            "hidden items stay out until asked for, and .git stays excluded even then",
            names(hidden: true).contains(".zshrc") && !names(hidden: true).contains(".git"))
        check(
            "asking for excluded folders lists them in place",
            names(excluded: true).prefix(4) == ["Alpha", "beta", "dist", "node_modules"])
        check("a filter keeps what matches every term", names(filter: "item 1") == ["Item 10.txt"])
        check(
            "a file is never excluded by a folder rule",
            names([entry("build"), entry("build", folder: true)]) == ["build"])
        let crowd = (0..<2_105).map { entry(String(format: "file-%05d", $0)) }
        let capped = FileBrowserListing(
            crowd, filter: "", showsHidden: false, showsExcluded: false, ignore: ignore)
        check(
            "a crowded folder lists its head and counts the rest",
            capped.entries.count == FileBrowserListing.limit && capped.hiddenByLimit == 105)

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
