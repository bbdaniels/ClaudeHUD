import Foundation

/// Which URL to open a saved vault through. The saved `path` is the source of
/// truth; the security-scoped bookmark is only an access aid, so a bookmark
/// that is missing, stale, unresolvable or pointing at another folder never
/// blocks a vault whose path exists. Pure, so it is unit-tested.
enum VaultAccess {
    /// What resolving the stored bookmark produced.
    enum Bookmark: Equatable {
        case none
        case failed
        case resolved(path: String, isStale: Bool)
    }

    struct Decision: Equatable {
        /// The folder to open, or nil when the saved path does not exist.
        let path: String?
        /// Start security-scoped access on the resolved bookmark URL.
        let useBookmarkScope: Bool
        /// Re-create the bookmark from `path` so stale data heals itself.
        let refreshBookmark: Bool

        static let missing = Decision(path: nil, useBookmarkScope: false, refreshBookmark: false)
    }

    static func decide(savedPath: String, pathExists: Bool, bookmark: Bookmark) -> Decision {
        guard pathExists else { return .missing }
        if case let .resolved(path, isStale) = bookmark, !isStale,
           standardized(path) == standardized(savedPath) {
            return Decision(path: savedPath, useBookmarkScope: true, refreshBookmark: false)
        }
        return Decision(path: savedPath, useBookmarkScope: false, refreshBookmark: true)
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
