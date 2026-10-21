import Foundation

/// Spotlight's side of Search Files: what a file says rather than what it is called.
enum FileContentQuery {
    private static let attributes = [
        "kMDItemTextContent", "kMDItemTitle", "kMDItemKeywords", "kMDItemDescription",
    ]

    /// Word-prefix matches, one group per term; a `.ext` word narrows by name, as it does there.
    static func expression(for query: String, filter: FileSearchFilter = .all) -> String? {
        let parsed = FileQuery(query)
        guard !parsed.words.isEmpty else { return nil }
        var clauses = parsed.words.map { term in
            "(" + attributes.map { "\($0) == \"\(escape(term))*\"cdw" }.joined(separator: " || ") + ")"
        }
        if !parsed.extensions.isEmpty {
            let names = parsed.extensions.map { "kMDItemFSName == \"*.\(escape($0))\"cd" }
            clauses.append(names.count == 1 ? names[0] : "(" + names.joined(separator: " || ") + ")")
        }
        if let types = filter.spotlightClause { clauses.append(types) }
        return clauses.joined(separator: " && ")
    }

    private static func escape(_ term: String) -> String {
        var escaped = ""
        for character in term {
            if ["\\", "\"", "*", "?"].contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
