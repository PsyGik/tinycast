import CoreServices
import Foundation

/// The opt-in second pass under the name matches; the disk index holds no file's text.
enum FileContentSearch {
    /// Twice the rows, so the ignore rules still leave candidates to show.
    static let candidateLimit = FileSearchQuery.resultLimit * 2

    nonisolated static func search(
        _ query: String, filter: FileSearchFilter, policy: FileSearchPolicy
    ) -> [FileSearchResult] {
        Signposts.interval("FileContentSearch.search") {
            guard !policy.roots.isEmpty,
                let expression = FileContentQuery.expression(for: query, filter: filter),
                let mdQuery = MDQueryCreate(nil, expression as CFString, nil, nil)
            else { return [] }
            MDQuerySetSearchScope(mdQuery, policy.roots.map { URL(filePath: $0) } as CFArray, 0)
            MDQuerySetMaxCount(mdQuery, candidateLimit)
            guard MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
            return (0..<MDQueryGetResultCount(mdQuery)).compactMap { index in
                guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { return nil }
                let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                    !isExcluded(path, policy: policy)
                else { return nil }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    return nil
                }
                return FileSearchResult(
                    url: URL(filePath: path), isDirectory: isDirectory.boolValue,
                    homeDirectory: policy.homeDirectory)
            }
        }
    }

    /// The crawl's own rules: no hidden path, nothing inside a bundle, no ignored folder.
    private nonisolated static func isExcluded(_ path: String, policy: FileSearchPolicy) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            let name = String(component)
            if name.hasPrefix(".") || policy.ignore.excludes(name: name, path: prefix) { return true }
            let ext = (name as NSString).pathExtension.lowercased()
            if FileSearchPolicy.bundleExtensions.contains(ext), prefix != path { return true }
        }
        return false
    }
}
