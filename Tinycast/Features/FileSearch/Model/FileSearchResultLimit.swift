import Foundation

/// How many ranked rows a search publishes; Spotlight is asked for twice that, at least 1,000.
enum FileSearchResultLimit: Int, CaseIterable, Identifiable, Sendable {
    case oneHundred = 100
    case twoHundred = 200
    case fiveHundred = 500
    case oneThousand = 1_000

    static let standard = Self.twoHundred

    var id: Int { rawValue }

    var title: String {
        rawValue.formatted()
    }
}
