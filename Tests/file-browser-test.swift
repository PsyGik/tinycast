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

        var tree = FileTreeIndex(root: "/Users/test/Development")
        let swift = tree.append(name: "Swift", parent: -1, isDirectory: true)
        let tinycast = tree.append(name: "tinycast", parent: swift, isDirectory: true)
        tree.append(name: "README.md", parent: tinycast, isDirectory: false)
        tree.append(name: "readme.md", parent: -1, isDirectory: false)
        tree.append(name: "AppIndex.swift", parent: tinycast, isDirectory: false)
        tree.append(name: "the_list_that_cut_forecast_go_live.sql", parent: -1, isDirectory: false)
        tree.append(name: "tinycast.config", parent: swift, isDirectory: false)
        tree.append(name: "Ünïcode notes.txt", parent: -1, isDirectory: false)
        func found(_ query: String) -> [String] { tree.search(query, limit: 10).map { tree.name(at: $0) } }

        check("a name is rebuilt into its full path", tree.path(at: 2) == "/Users/test/Development/Swift/tinycast/README.md")
        check("depth counts the folders below the root", tree.depth(at: 2) == 2 && tree.depth(at: 0) == 0)
        check("an exact name beats a deeper copy of it", found("readme.md").first == "readme.md")
        tree.append(name: "CONTRIBUTING.md", parent: -1, isDirectory: false)
        tree.append(name: "content", parent: tinycast, isDirectory: true)
        check(
            "within one kind of hit the nearer item wins, however short the deeper name",
            found("con").first == "CONTRIBUTING.md")
        check(
            "a stronger kind of hit still wins from deeper down",
            found("content").first == "content")
        check(
            "the field reads a folder as its path and a slash, the root as itself",
            FileBrowserPath.typed(home.appending(path: "Development"), home: home) == "~/Development/"
                && FileBrowserPath.typed(home, home: home) == "~/"
                && FileBrowserPath.typed(URL(fileURLWithPath: "/"), home: home) == "/")
        check("initials find a camel-cased name", found("appidx").first == "AppIndex.swift")
        tree.append(name: "tc_fg_with_a_much_longer_tail.md", parent: -1, isDirectory: false)
        tree.append(name: "tc_fg.md", parent: -1, isDirectory: false)
        check(
            "letters on word starts are initials, and beat the same letters landing mid-word",
            found("tcfg").firstIndex(of: "the_list_that_cut_forecast_go_live.sql")!
                < found("tcfg").firstIndex(of: "tinycast.config")!)
        check(
            "between equally tight hits the shorter name wins",
            found("tcfg").firstIndex(of: "tc_fg.md")! < found("tcfg").firstIndex(of: "tc_fg_with_a_much_longer_tail.md")!)
        check("a name with no letters in order is never a hit", found("zzz").isEmpty)
        check("an accented name is found by its plain letters", found("unicode").first == "Ünïcode notes.txt")
        check("an empty query finds nothing", found("").isEmpty)

        check(
            "tab completes the folder's shared prefix, in the names' own case",
            FileBrowserCompletion.sharedPrefix(of: ["Development", "Developer", "Desktop"], extending: "dev")
                == "Develop")
        check(
            "a single match completes to the whole name",
            FileBrowserCompletion.sharedPrefix(of: ["Downloads", "Desktop"], extending: "do") == "Downloads")
        check(
            "nothing starting with the text completes nothing",
            FileBrowserCompletion.sharedPrefix(of: ["Desktop"], extending: "x") == nil)
        let base = URL(fileURLWithPath: "/Users/test/Development")
        check(
            "a deep result names the folders between it and the browsed folder",
            FileBrowserPath.between(base, and: base.appending(path: "Swift/tinycast/README.md")) == "Swift/tinycast")
        check(
            "a direct child names none",
            FileBrowserPath.between(base, and: base.appending(path: "README.md")) == nil)
        check(
            "only a strict subtree is walked; home, the root and their ancestors go to Spotlight",
            FileTreeIndexer.walks(base, home: home) && !FileTreeIndexer.walks(home, home: home)
                && !FileTreeIndexer.walks(URL(fileURLWithPath: "/"), home: home)
                && !FileTreeIndexer.walks(URL(fileURLWithPath: "/Users"), home: home))
        check(
            "the folders macOS guards are never entered from above",
            FileTreeIndexer.protectedFolders(home: home).contains("/Users/test/Documents"))
        check(
            "Spotlight gets each word's letters in order, the words in any order",
            FileSearchQuery.subsequenceExpression(for: "ab cd")
                == "kMDItemFSName == \"*a*b*\"cd && kMDItemFSName == \"*c*d*\"cd")
        check(
            "a type word reaches Spotlight as the end of the name, with the header's filter",
            FileSearchQuery.subsequenceExpression(for: FileQuery(".pdf inv"), filter: .images)
                == "kMDItemFSName == \"*i*n*v*\"cd && kMDItemFSName == \"*.pdf\"cd && "
                + FileSearchFilter.images.spotlightClause!)

        let parsed = FileQuery("  .pdf  annual .TAR.gz report . ")
        check(
            "a dotted word is a type, lowercased; the rest, a lone dot included, are words",
            parsed.words == ["annual", "report", "."] && parsed.extensions == ["pdf", "tar.gz"])
        check(
            "a type word keeps only files ending in it, never a folder",
            FileQuery(".pdf").admits(name: "Invoice.PDF", isDirectory: false)
                && !FileQuery(".pdf").admits(name: "Invoice.pdf.txt", isDirectory: false)
                && !FileQuery(".pdf").admits(name: "manual.pdf", isDirectory: true))
        check(".zshrc finds the dotfile it names", FileQuery(".zshrc").admits(name: ".zshrc", isDirectory: false))

        var words = FileTreeIndex(root: "/Users/test/Documents")
        let reports = words.append(name: "Reports", parent: -1, isDirectory: true)
        words.append(name: "annual-report-2025.pdf", parent: reports, isDirectory: false)
        words.append(name: "annual-report-2025.key", parent: reports, isDirectory: false)
        words.append(name: "monthly report.pdf", parent: -1, isDirectory: false)
        words.append(name: "README.md", parent: -1, isDirectory: false)
        words.append(name: "notes.md", parent: reports, isDirectory: false)
        words.append(name: "photo.png", parent: -1, isDirectory: false)
        words.append(name: "invoice-march.pdf", parent: -1, isDirectory: false)
        func hits(_ text: String) -> [String] { words.search(text, limit: 10).map { words.name(at: $0) } }

        check(
            "words match in any order, each on its own",
            hits("report annual").prefix(2).sorted() == ["annual-report-2025.key", "annual-report-2025.pdf"])
        check("every word must hit", !hits("report annual").contains("monthly report.pdf"))
        check(
            "a type word narrows the words to that type",
            hits(".pdf report").sorted() == ["annual-report-2025.pdf", "monthly report.pdf"])
        check(
            "a type word alone lists every file of it, nearest first",
            hits(".md") == ["README.md", "notes.md"])
        check("a type word never lists a folder", !hits(".pdf").contains("Reports"))
        check("a swapped pair is forgiven", hits("raedme") == ["README.md"])
        check("a mistyped letter is forgiven", hits("readmw").first == "README.md")
        check("an extra letter is forgiven", hits("readdme").first == "README.md")
        check("a missing letter was never a typo: in-order letters already match", hits("rdme").first == "README.md")
        check("a typo works inside a type word's narrowing", hits(".pdf invioce") == ["invoice-march.pdf"])
        check("two slips in one word are too far to guess", hits("raedmw").isEmpty)
        var noisy = FileTreeIndex(root: "/Users/test")
        noisy.append(name: "in-various-old-pieces-of-oceanography.txt", parent: -1, isDirectory: false)
        noisy.append(name: "invoice.pdf", parent: -1, isDirectory: false)
        check(
            "letters scattered through a long name do not hide the word one slip away, which ranks first",
            noisy.search("invioce", limit: 5).map { noisy.name(at: $0) }.first == "invoice.pdf")
        check("a short word gets no typo guesses", hits("pgn").isEmpty)
        let accepted = words.search(FileQuery("report"), limit: 10) { name, _ in name.hasSuffix(".key") }
        check(
            "the caller's filter sees only names that matched, and narrows them",
            accepted.map { words.name(at: $0) } == ["annual-report-2025.key"])

        check(
            "typo matching is one edit, anywhere in the name",
            FileTypo.matches(Array("invoice".utf8), in: ArraySlice(Array("my-invioce.pdf".utf8)))
                && FileTypo.matches(Array("invoice".utf8), in: ArraySlice(Array("INVOCE".utf8)))
                && !FileTypo.matches(Array("invoice".utf8), in: ArraySlice(Array("nvoce".utf8)))
                && !FileTypo.matches(Array("abc".utf8), in: ArraySlice(Array("abd".utf8))))

        var cache: [String: Bool] = [:]
        check(
            "the type filter reads a file's kind from its name",
            FileSearchFilter.images.accepts(name: "a.PNG", isDirectory: false, cache: &cache)
                && !FileSearchFilter.images.accepts(name: "a.txt", isDirectory: false, cache: &cache)
                && FileSearchFilter.folders.accepts(name: "src", isDirectory: true, cache: &cache)
                && !FileSearchFilter.images.accepts(name: "src", isDirectory: true, cache: &cache)
                && FileSearchFilter.all.accepts(name: "x", isDirectory: true, cache: &cache))
        let typed = FileBrowserListing(
            [entry("src", folder: true), entry("a.png"), entry("b.txt")], filter: "", showsHidden: false,
            showsExcluded: false, ignore: ignore, type: .images)
        check(
            "under a type filter the folder keeps its folders, the way on",
            typed.entries.map(\.name) == ["src", "a.png"])
        let foldersOnly = FileBrowserListing(
            [entry("src", folder: true), entry("a.png")], filter: "", showsHidden: false,
            showsExcluded: false, ignore: ignore, type: .folders)
        check("the Folders filter lists folders alone", foldersOnly.entries.map(\.name) == ["src"])

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
