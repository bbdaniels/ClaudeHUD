import Foundation

struct NoteFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let relativePath: String
    let isDirectory: Bool
    let modificationDate: Date?
    var children: [NoteFile]?

    /// Most recent modification date among this file or any children.
    var latestModification: Date? {
        if let children {
            let childDates = children.compactMap { $0.latestModification }
            let dates = [modificationDate].compactMap { $0 } + childDates
            return dates.max()
        }
        return modificationDate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: NoteFile, rhs: NoteFile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Obsidian String Helpers

extension String {
    func containsAllTerms(_ substrings: [Substring]) -> Bool {
        substrings.allSatisfy { self.contains($0) }
    }

    func encodedForObsidianURL() -> String {
        var path = self
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }
        return path
            .components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }
            .joined(separator: "%2F")
    }
}
