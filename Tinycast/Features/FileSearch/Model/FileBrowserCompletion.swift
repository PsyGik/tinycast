import Foundation

enum FileBrowserCompletion {
    /// The longest start every name beginning with `typed` shares, case-blind, in the names' own case.
    static func sharedPrefix(of names: [String], extending typed: String) -> String? {
        let matches = names.filter { $0.range(of: typed, options: [.caseInsensitive, .anchored]) != nil }
        guard var prefix = matches.first else { return nil }
        for name in matches.dropFirst() {
            while !prefix.isEmpty, name.range(of: prefix, options: [.caseInsensitive, .anchored]) == nil {
                prefix.removeLast()
            }
        }
        return prefix
    }
}
