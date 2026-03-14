import Foundation

struct NoteFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let relativePath: String
    let isDirectory: Bool
    var children: [NoteFile]?

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
