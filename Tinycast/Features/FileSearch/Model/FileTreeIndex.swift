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
        String(decoding: nameBytes(at: index), as: UTF8.self)
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

    /// The best `limit` matches: fuzzy score first, then nearer the root, then the name.
    func search(_ query: String, limit: Int) -> [Int] {
        let folded = FuzzyMatch.Query(query)
        guard !folded.isEmpty else { return [] }
        let needle = Array(FuzzyMatch.normalized(query).utf8)
        let asciiNeedle = needle.allSatisfy { $0 < 0x80 }
        var hits: [(index: Int, score: Int, depth: Int)] = []
        for index in 0..<count {
            let slice = nameBytes(at: index)
            // Most names fail a byte-level in-order check, so few ever become a `String`.
            if asciiNeedle, slice.allSatisfy({ $0 < 0x80 }), !Self.containsInOrder(needle, slice) {
                continue
            }
            guard let score = FileNameScore.score(folded, name(at: index)) else { continue }
            hits.append((index, score, depth(at: index)))
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
    /// A letters-in-order hit scores by how tightly it lands, less the name's length, so
    /// `tinycast.config` beats a long name that happens to scatter the same letters.
    static func score(_ query: FuzzyMatch.Query, _ name: String) -> Int? {
        guard let match = FuzzyMatch.match(query, candidate: name) else { return nil }
        guard match.tier == .subsequence else { return match.score }
        return match.spread * 4 - match.candidateLength
    }

    /// The kind of hit a score came from — exact, prefix, word start, substring or loose — so a
    /// nearer item wins within one kind, while a stronger kind still wins from any depth.
    static func band(_ score: Int) -> Int {
        score >= 70_000 ? score / 10_000 : 0
    }
}
