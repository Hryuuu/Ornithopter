import Foundation

/// Identifies the latest request even after it completes, so metadata probes
/// cannot update entries belonging to a subsequently refreshed listing.
nonisolated struct RemoteListingRequests {
    private var latest: [String: UUID] = [:]

    mutating func begin(path: String) -> UUID {
        let request = UUID()
        latest[path] = request
        return request
    }

    func finish(path: String, request: UUID) -> Bool { latest[path] == request }
    func version(path: String) -> UUID? { latest[path] }
    mutating func invalidateSubtree(_ path: String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        latest = latest.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
    }
    mutating func invalidateAll() { latest.removeAll() }
}
