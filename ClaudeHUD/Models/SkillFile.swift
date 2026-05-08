import Foundation

/// One Claude Code skill (`SKILL.md` plus its parent dir).
///
/// Path layout examples (under `~/.claude/skills/`):
///   - `commit/SKILL.md`               → name: "commit",         group: "core"
///   - `railway-domain/SKILL.md`       → name: "railway-domain", group: "railway"
///   - `gstack/qa/SKILL.md`            → name: "gstack:qa",      group: "gstack"
///   - `caveman:caveman/SKILL.md` (top dir literally has colon, treat as flat)
struct SkillFile: Identifiable, Hashable {
    let id: String                  // absolute file path — stable, unique
    let displayName: String         // user-facing invocation name (`commit`, `gstack:qa`)
    let group: String               // grouping bucket
    let path: URL                   // SKILL.md absolute URL
    let folder: URL                 // skill directory
    var raw: String                 // full file contents (frontmatter + body)
    var frontmatter: [String: String]
    var body: String                // body after frontmatter
    var isNested: Bool              // true if nested under parent skill dir

    var summary: String { frontmatter["description"] ?? "" }
    var allowedTools: String { frontmatter["allowed-tools"] ?? "" }
    var argumentHint: String { frontmatter["argument-hint"] ?? "" }
    var taggedFamily: String? {
        let v = frontmatter["family"]?.trimmingCharacters(in: .whitespaces)
        return (v?.isEmpty == false) ? v : nil
    }
    var taggedSubfamily: String? {
        let v = frontmatter["subfamily"]?.trimmingCharacters(in: .whitespaces)
        return (v?.isEmpty == false) ? v : nil
    }

    /// Reassemble file contents from current frontmatter + body.
    func reassemble() -> String {
        var lines: [String] = ["---"]
        // Preserve canonical key order if present, else alpha.
        let order = ["name", "description", "argument-hint", "allowed-tools", "disable-model-invocation"]
        var seen = Set<String>()
        for key in order where frontmatter[key] != nil {
            lines.append("\(key): \(frontmatter[key]!)")
            seen.insert(key)
        }
        for (key, value) in frontmatter.sorted(by: { $0.key < $1.key }) where !seen.contains(key) {
            lines.append("\(key): \(value)")
        }
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }
}

enum SkillFrontmatter {
    /// Minimal YAML frontmatter parser sufficient for SKILL.md files.
    /// Handles: scalar `key: value`, block scalar `key: |` / `key: >`, and list items (`- item`).
    /// Returns (frontmatter dict, body string). If no frontmatter, returns ([:], raw).
    static func split(_ raw: String) -> (front: [String: String], body: String) {
        guard raw.hasPrefix("---") else { return ([:], raw) }
        var lines = raw.components(separatedBy: "\n")
        lines.removeFirst() // drop opening `---`
        var front: [String: String] = [:]
        var bodyStart = lines.count

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                bodyStart = i + 1
                break
            }
            if trimmed.isEmpty { i += 1; continue }

            guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let valueRaw = String(line[line.index(after: colon)...])
            let value = valueRaw.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { i += 1; continue }

            // Block scalar: `key: |` or `key: >`. Preserves blank lines and relative
            // indentation; strips only the common leading indent.
            if value == "|" || value == ">" || value == "|-" || value == ">-" {
                i += 1
                var rawCollected: [String] = []
                while i < lines.count {
                    let next = lines[i]
                    let nextTrim = next.trimmingCharacters(in: .whitespaces)
                    if nextTrim == "---" { break }
                    // Stop on next top-level key.
                    if !next.hasPrefix(" ") && !next.hasPrefix("\t") && !nextTrim.isEmpty
                        && next.firstIndex(of: ":") != nil
                        && !nextTrim.hasPrefix("- ") {
                        break
                    }
                    rawCollected.append(next)
                    i += 1
                }
                // Determine common leading indent across non-empty lines.
                let nonEmpty = rawCollected.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let commonIndent: Int = nonEmpty.map { line -> Int in
                    line.prefix(while: { $0 == " " || $0 == "\t" }).count
                }.min() ?? 0
                let stripped: [String] = rawCollected.map { line in
                    if line.count >= commonIndent {
                        return String(line.dropFirst(commonIndent))
                    }
                    return line
                }
                let folded = (value == ">" || value == ">-")
                let joined: String
                if folded {
                    // Folded: newlines → spaces, empty lines → paragraph break.
                    var out: [String] = []
                    var paragraph: [String] = []
                    for line in stripped {
                        if line.trimmingCharacters(in: .whitespaces).isEmpty {
                            if !paragraph.isEmpty {
                                out.append(paragraph.joined(separator: " "))
                                paragraph = []
                            }
                            out.append("")
                        } else {
                            paragraph.append(line.trimmingCharacters(in: .whitespaces))
                        }
                    }
                    if !paragraph.isEmpty { out.append(paragraph.joined(separator: " ")) }
                    joined = out.joined(separator: "\n")
                } else {
                    // Literal: preserve newlines and blank lines.
                    joined = stripped.joined(separator: "\n")
                }
                // Strip trailing newlines for `|-` / `>-`; otherwise keep one.
                let stripTrailing = (value == "|-" || value == ">-")
                front[key] = stripTrailing
                    ? joined.trimmingCharacters(in: .whitespacesAndNewlines)
                    : joined.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                continue
            }

            // List value: `key:` followed by `- item` lines
            if value.isEmpty {
                i += 1
                var items: [String] = []
                while i < lines.count {
                    let next = lines[i]
                    let nextTrim = next.trimmingCharacters(in: .whitespaces)
                    if nextTrim == "---" { break }
                    if nextTrim.hasPrefix("- ") {
                        items.append(String(nextTrim.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                        i += 1
                        continue
                    }
                    if nextTrim.isEmpty { i += 1; continue }
                    break
                }
                if !items.isEmpty {
                    front[key] = items.joined(separator: ", ")
                }
                continue
            }

            // Scalar value
            front[key] = value
            i += 1
        }

        let body = lines.dropFirst(bodyStart).joined(separator: "\n")
        return (front, body)
    }
}
