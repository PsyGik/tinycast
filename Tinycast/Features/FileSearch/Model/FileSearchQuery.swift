import Foundation

enum FileSearchQuery {
    static let candidateLimit = 1_000
    static let resultLimit = 200
    /// A blank screen is a shortlist, not a browser: enough rows to reach, never to scroll far.
    static let recentLimit = 20

    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \Character.isWhitespace).map(String.init)
    }

    static func expression(
        for query: String, excluding exclusions: [String] = [], filter: FileSearchFilter = .all
    ) -> String? {
        let parsed = FileQuery(query)
        guard !parsed.isEmpty else { return nil }
        var matches = parsed.words.map { "kMDItemFSName == \"*\(escape($0))*\"cd" }
        if let types = extensionClause(parsed.extensions) { matches.append(types) }
        // Excluding in the predicate keeps ignored files from consuming the candidate cap.
        let excludes = exclusions.map { "kMDItemFSName != \"\(escapeGlob($0))\"cd" }
        let types = filter.spotlightClause.map { [$0] } ?? []
        return (matches + types + excludes).joined(separator: " && ")
    }

    /// Each word's letters in order, anywhere in the name, the words in any order: Spotlight's
    /// nearest thing to fuzzy, with a `.ext` word anchored to the end.
    static func subsequenceExpression(
        for query: FileQuery, filter: FileSearchFilter = .all, excluding exclusions: [String] = []
    ) -> String? {
        var clauses = query.words.compactMap { word -> String? in
            let letters = word.filter { !$0.isWhitespace }
            guard !letters.isEmpty else { return nil }
            return "kMDItemFSName == \"*" + letters.map { escape(String($0)) + "*" }.joined() + "\"cd"
        }
        if let types = extensionClause(query.extensions) { clauses.append(types) }
        guard !clauses.isEmpty else { return nil }
        let types = filter.spotlightClause.map { [$0] } ?? []
        let excludes = exclusions.map { "kMDItemFSName != \"\(escapeGlob($0))\"cd" }
        return (clauses + types + excludes).joined(separator: " && ")
    }

    static func subsequenceExpression(for query: String, excluding exclusions: [String] = []) -> String? {
        subsequenceExpression(for: FileQuery(query), excluding: exclusions)
    }

    /// Any of the typed types, each as the end of the name.
    private static func extensionClause(_ extensions: [String]) -> String? {
        guard !extensions.isEmpty else { return nil }
        let clauses = extensions.map { "kMDItemFSName == \"*.\(escape($0))\"cd" }
        return clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: " || ") + ")"
    }

    /// Word-prefix matches on what a file says rather than what it is called, one group per term.
    static func contentExpression(
        for query: String, excluding exclusions: [String] = [], filter: FileSearchFilter = .all
    ) -> String? {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return nil }
        let matches = terms.map { term in
            let clauses = contentAttributes.map { "\($0) == \"\(escape(term))*\"cdw" }
            return "(" + clauses.joined(separator: " || ") + ")"
        }
        let excludes = exclusions.map { "kMDItemFSName != \"\(escapeGlob($0))\"cd" }
        let types = filter.spotlightClause.map { [$0] } ?? []
        return (matches + types + excludes).joined(separator: " && ")
    }

    private static let contentAttributes = [
        "kMDItemTextContent", "kMDItemTitle", "kMDItemKeywords", "kMDItemDescription",
    ]

    /// Both, because macOS stamps `kMDItemLastUsedDate` on few opens now, and Spotlight sorts on one.
    enum RecentStamp: String, CaseIterable, Sendable {
        case changed = "kMDItemFSContentChangeDate"
        case used = "kMDItemLastUsedDate"

        /// Spotlight's own literal, so no clock is injected; editing is constant, so it is shorter.
        var window: String {
            switch self {
            case .changed: return "$time.now(-259200)"
            case .used: return "$time.now(-2592000)"
            }
        }
    }

    static func recentExpression(
        stamp: RecentStamp, excluding exclusions: [String] = [], filter: FileSearchFilter = .all
    ) -> String {
        let touched = "\(stamp.rawValue) > \(stamp.window)"
        let types = filter.spotlightClause.map { [$0] } ?? []
        let excludes = exclusions.map { "kMDItemFSName != \"\(escapeGlob($0))\"cd" }
        return ([touched] + types + excludes).joined(separator: " && ")
    }

    static func rank(
        _ results: [FileSearchResult], for query: String, ignoring ignore: FileSearchIgnoreList,
        limit: Int = resultLimit
    ) -> [FileSearchResult] {
        let parsed = FileQuery(query)
        guard !parsed.isEmpty else { return [] }
        // A `.ext` word filtered the candidates already; only the words rank them.
        let words = parsed.words.joined(separator: " ")
        let terms = parsed.words
        // Folded once each: a thousand candidates would otherwise re-fold every term per result.
        let whole = FuzzyMatch.Query(words)
        let folded = terms.map(FuzzyMatch.Query.init)
        return results.filter { !isExcludedPath($0.id, ignoring: ignore) }.map { result in
            let full = FuzzyMatch.score(whole, candidate: result.name)
            let termScore = folded.compactMap { FuzzyMatch.score($0, candidate: result.name) }
                .reduce(0, +)
            return (result, full, termScore)
        }
        .sorted { left, right in
            switch (left.1, right.1) {
            case let (leftScore?, rightScore?) where leftScore != rightScore:
                return leftScore > rightScore
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if left.2 != right.2 { return left.2 > right.2 }
                let nameOrder = left.0.name.localizedCaseInsensitiveCompare(right.0.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return left.0.id.localizedCaseInsensitiveCompare(right.0.id) == .orderedAscending
            }
        }
        .prefix(limit)
        .map(\.0)
    }

    static func matches(filename: String, query: String, isDirectory: Bool = false) -> Bool {
        let parsed = FileQuery(query)
        guard parsed.admits(name: filename, isDirectory: isDirectory) else { return false }
        return parsed.words.allSatisfy { term in
            filename.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Hidden paths and bundle contents are what keep File Search permission-free.
    static func isExcludedPath(_ path: String, ignoring ignore: FileSearchIgnoreList) -> Bool {
        let structural = path.split(separator: "/").contains { component in
            (component.hasPrefix(".") && component != "." && component != "..")
                || component.lowercased().hasSuffix(".app")
        }
        return structural || ignore.excludes(path: path)
    }

    /// A typed term is literal, so its wildcards are neutralized along with the string delimiters.
    private static func escape(_ term: String) -> String {
        quoting(term, escaping: ["\\", "\"", "*", "?"])
    }

    /// A user pattern keeps its `*`, since that is the one wildcard Spotlight evaluates.
    private static func escapeGlob(_ pattern: String) -> String {
        quoting(pattern, escaping: ["\\", "\""])
    }

    private static func quoting(_ text: String, escaping characters: Set<Character>) -> String {
        var escaped = ""
        for character in text {
            if characters.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
