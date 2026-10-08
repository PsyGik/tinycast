import Foundation

/// The names under one folder, packed for a low footprint: about 30 bytes an item, freed on leave.
struct FileTreeIndex: Sendable {
    /// Past this the walk stops and Spotlight covers the rest, so memory stays bounded.
    static let capacity = 100_000

    let root: String
    /// Every name's UTF-8, back to back; a `String` per item would cost several times as much.
    private var bytes: [UInt8] = []
    /// Where each name starts in `bytes`; the next one's start is where it ends.
    private var starts: [UInt32] = []
    /// The folder an item sits in, as an index here, or -1 for `root` itself.
    private var parents: [Int32] = []
    private var folders: [Bool] = []
    /// True when the walk stopped at `capacity` or its time budget before reaching every folder.
    var isTruncated = false

    init(root: String) {
        self.root = root
    }

    var count: Int { starts.count }

    /// Returns the item's index, which a child passes back as its `parent`.
    @discardableResult
    mutating func append(name: String, parent: Int32, isDirectory: Bool) -> Int32 {
        starts.append(UInt32(bytes.count))
        bytes.append(contentsOf: name.utf8)
        parents.append(parent)
        folders.append(isDirectory)
        return Int32(starts.count - 1)
    }

    func name(at index: Int) -> String {
        String(validating: nameBytes(at: index), as: UTF8.self) ?? ""
    }

    func isDirectory(at index: Int) -> Bool { folders[index] }

    /// Built only for what is shown, by walking the parent links up to `root`.
    func path(at index: Int) -> String {
        var components: [String] = []
        var current = Int32(index)
        while current >= 0 {
            components.append(name(at: Int(current)))
            current = parents[Int(current)]
        }
        return ([root == "/" ? "" : root] + components.reversed()).joined(separator: "/")
    }

    func depth(at index: Int) -> Int {
        var depth = 0
        var current = parents[index]
        while current >= 0 {
            depth += 1
            current = parents[Int(current)]
        }
        return depth
    }

    private func nameBytes(at index: Int) -> ArraySlice<UInt8> {
        let start = Int(starts[index])
        let end = index + 1 < starts.count ? Int(starts[index + 1]) : bytes.count
        return bytes[start..<end]
    }

    func search(_ text: String, limit: Int) -> [Int] {
        search(FileQuery(text), limit: limit)
    }

    /// The best `limit` matches: kind of hit, then nearer the root, then score, then name.
    /// `accept` sees only names that already matched, so a costly check runs on a few dozen.
    func search(
        _ query: FileQuery, limit: Int, accept: (_ name: String, _ isDirectory: Bool) -> Bool = { _, _ in true }
    ) -> [Int] {
        guard !query.isEmpty else { return [] }
        let folded = FileQuery.Folded(query)
        let extensions = query.extensions.map { Array(("." + $0).utf8) }
        var hits: [(index: Int, score: Int, depth: Int)] = []
        for index in 0..<count {
            let slice = nameBytes(at: index)
            if !extensions.isEmpty, folders[index] || !Self.endsWithAny(slice, extensions) { continue }
            // Most names fail a byte-level in-order check, so few ever become a `String`.
            if let words = folded.wordBytes, slice.allSatisfy({ $0 < 0x80 }),
                !words.allSatisfy({ Self.containsInOrder($0, slice) })
            {
                continue
            }
            let name = name(at: index)
            guard let score = FileQuery.score(folded, name), accept(name, folders[index]) else { continue }
            hits.append((index, score, depth(at: index)))
        }
        // Loose letters-in-order hits are no reason to skip it: those are what a typo looks like.
        let literal = Set(
            hits.filter { FileNameScore.band($0.score) >= FileNameScore.literalBand }.map(\.index))
        if literal.count < Self.typoThreshold, let words = folded.wordBytes,
            words.contains(where: { $0.count >= FileTypo.minimumLength })
        {
            // A loose hit one slip from the word is that word mistyped: it moves up to a typo's rank.
            let typos = typoHits(words, extensions: extensions, skipping: literal, accept: accept)
            let upgraded = Set(typos.map(\.index))
            hits = hits.filter { !upgraded.contains($0.index) } + typos
        }
        return
            hits
            .sorted { left, right in
                let leftBand = FileNameScore.band(left.score)
                let rightBand = FileNameScore.band(right.score)
                if leftBand != rightBand { return leftBand > rightBand }
                if left.depth != right.depth { return left.depth < right.depth }
                if left.score != right.score { return left.score > right.score }
                return name(at: left.index).localizedStandardCompare(name(at: right.index))
                    == .orderedAscending
            }
            .prefix(limit)
            .map(\.index)
    }

    /// Below this many hits a slip of the finger is likelier than a missing file, so look again.
    static let typoThreshold = 5

    /// Names every word reaches either as typed or within one slip, at least one by a slip.
    private func typoHits(
        _ words: [[UInt8]], extensions: [[UInt8]], skipping matched: Set<Int>,
        accept: (String, Bool) -> Bool
    ) -> [(index: Int, score: Int, depth: Int)] {
        var hits: [(index: Int, score: Int, depth: Int)] = []
        for index in 0..<count where !matched.contains(index) {
            let slice = nameBytes(at: index)
            guard slice.allSatisfy({ $0 < 0x80 }) else { continue }
            if !extensions.isEmpty, folders[index] || !Self.endsWithAny(slice, extensions) { continue }
            var slipped = false
            let reached = words.allSatisfy { word in
                if Self.containsLiterally(word, slice) { return true }
                guard FileTypo.matches(word, in: slice) else { return false }
                slipped = true
                return true
            }
            guard reached, slipped else { continue }
            let name = name(at: index)
            guard accept(name, folders[index]) else { continue }
            hits.append((index, FileQuery.typoScore(for: name), depth(at: index)))
        }
        return hits
    }

    /// The word as one run of the name, case-blind; a typo pass counts nothing looser as typed.
    private static func containsLiterally(_ word: [UInt8], _ name: ArraySlice<UInt8>) -> Bool {
        guard !word.isEmpty, name.count >= word.count else { return word.isEmpty }
        let bytes = Array(name)
        for start in 0...(bytes.count - word.count) {
            var hit = true
            for offset in 0..<word.count {
                let byte = bytes[start + offset]
                if (byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte) != word[offset] {
                    hit = false
                    break
                }
            }
            if hit { return true }
        }
        return false
    }

    /// Case-blind suffix test on raw bytes: `.PDF` is a `.pdf`.
    private static func endsWithAny(_ name: ArraySlice<UInt8>, _ suffixes: [[UInt8]]) -> Bool {
        suffixes.contains { suffix in
            guard name.count >= suffix.count else { return false }
            return zip(name.suffix(suffix.count), suffix).allSatisfy { byte, wanted in
                (byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte) == wanted
            }
        }
    }

    /// Case-blind for ASCII, which is all this fast path ever sees.
    private static func containsInOrder(_ needle: [UInt8], _ haystack: ArraySlice<UInt8>) -> Bool {
        var position = needle.startIndex
        for byte in haystack where position < needle.endIndex {
            let lowered = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
            if lowered == needle[position] { position += 1 }
        }
        return position == needle.endIndex
    }
}

/// How well a typed query names a file: the launcher's tiers, with short names ahead among the loose.
enum FileNameScore {
    /// A letters-in-order hit scores by how tightly it lands, less twice the name's length, so
    /// `tinycast.config` beats a long name that happens to scatter the same letters.
    static func score(_ query: FuzzyMatch.Query, _ name: String) -> Int? {
        guard let match = FuzzyMatch.match(query, candidate: name) else { return nil }
        guard match.tier == .subsequence else { return match.score }
        return match.spread * 4 - match.candidateLength * 2
    }

    /// The kind of hit a score came from — exact, prefix, word start, substring or loose — so a
    /// nearer item wins within one kind, while a stronger kind still wins from any depth.
    static func band(_ score: Int) -> Int {
        score >= 60_000 ? score / 10_000 : 0
    }

    /// Substring and stronger: a name that holds the word as typed.
    static let literalBand = 7
}
