import Foundation

/// Typed text split the way people type it: `.pdf invoice` is a file type and a word.
struct FileQuery: Equatable, Sendable {
    /// The words a name must hold, each on its own, in any order.
    let words: [String]
    /// Lowercased and without the dot: `.tar.gz` is `tar.gz`.
    let extensions: [String]

    init(_ raw: String) {
        var words: [String] = []
        var extensions: [String] = []
        for token in raw.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.count > 1, token.hasPrefix("."), token.dropFirst().contains(where: \.isLetter) {
                extensions.append(token.dropFirst().lowercased())
            } else {
                words.append(token)
            }
        }
        self.words = words
        self.extensions = extensions
    }

    var isEmpty: Bool { words.isEmpty && extensions.isEmpty }

    /// A type word keeps only files ending in it; `.zshrc` therefore also finds the dotfile itself.
    func admits(name: String, isDirectory: Bool) -> Bool {
        guard !extensions.isEmpty else { return true }
        guard !isDirectory else { return false }
        let lowered = name.lowercased()
        return extensions.contains { lowered.hasSuffix("." + $0) }
    }

    /// Folded once per search, so ranking a hundred thousand names never re-folds a word.
    struct Folded: Sendable {
        fileprivate let whole: FuzzyMatch.Query?
        fileprivate let words: [FuzzyMatch.Query]
        /// Each word's folded UTF-8, for the byte-level checks; nil when a word is not ASCII.
        let wordBytes: [[UInt8]]?

        init(_ query: FileQuery) {
            words = query.words.map(FuzzyMatch.Query.init)
            whole = query.words.count > 1 ? FuzzyMatch.Query(query.words.joined(separator: " ")) : nil
            let bytes = query.words.map { Array(FuzzyMatch.normalized($0).utf8) }
            wordBytes = bytes.allSatisfy { $0.allSatisfy { $0 < 0x80 } } ? bytes : nil
        }
    }

    /// Every word must hit; the weakest decides, unless the words read better as one phrase.
    static func score(_ folded: Folded, _ name: String) -> Int? {
        guard !folded.words.isEmpty else { return typeOnlyScore }
        guard folded.words.count > 1 else { return FileNameScore.score(folded.words[0], name) }
        let phrase = folded.whole.flatMap { FileNameScore.score($0, name) }
        var weakest = Int.max
        for word in folded.words {
            guard let score = FileNameScore.score(word, name) else { return phrase }
            weakest = min(weakest, score)
        }
        return max(phrase ?? .min, weakest)
    }

    /// A type word alone ranks every file of that type alike, so depth and name order them.
    static let typeOnlyScore = 1

    /// A whole word one slip away outranks letters scattered through a long name, and every
    /// literal hit outranks it; shorter names first.
    static func typoScore(for name: String) -> Int {
        69_999 - min(name.count, 9_999)
    }
}

/// One slip in a word — a letter extra, missing, swapped or mistyped — still finds the name.
enum FileTypo {
    /// Shorter words have too many neighbours one letter away: four less one is a fragment
    /// half the disk contains.
    static let minimumLength = 5

    /// Whether `word` appears in `name` within one edit, both folded ASCII bytes.
    static func matches(_ word: [UInt8], in name: ArraySlice<UInt8>) -> Bool {
        let m = word.count
        guard m >= minimumLength else { return false }
        let text = Array(name)
        // Columns of edit distance over the word; a match may start anywhere in the name.
        var older = [Int](repeating: 0, count: m + 1)
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        for i in 1...max(text.count, 1) where i <= text.count {
            let t = lower(text[i - 1])
            current[0] = 0
            for j in 1...m {
                let substitution = previous[j - 1] + (word[j - 1] == t ? 0 : 1)
                var best = min(substitution, previous[j] + 1, current[j - 1] + 1)
                if j > 1, i > 1, word[j - 1] == lower(text[i - 2]), word[j - 2] == t {
                    best = min(best, older[j - 2] + 1)
                }
                current[j] = best
            }
            if current[m] <= 1 { return true }
            (older, previous, current) = (previous, current, older)
        }
        return false
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }
}
