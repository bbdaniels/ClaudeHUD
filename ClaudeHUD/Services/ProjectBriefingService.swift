import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "ProjectBriefing")

// MARK: - Project Briefing Model

struct ProjectBriefing: Identifiable, Codable {
    let id: String  // project id
    let summary: String
    let status: String
    let priorities: [String]
    let blockers: [String]
    let nextActions: [String]
    var isLoading: Bool = false
    var error: String? = nil
    var generatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, summary, status, priorities, blockers, nextActions, generatedAt
    }
}

// MARK: - Cache Entry

private struct CachedBriefing: Codable {
    let briefing: ProjectBriefing
    let generatedAt: Date
}

// MARK: - Project Briefing Service

@MainActor
class ProjectBriefingService: ObservableObject {
    @Published var briefings: [String: ProjectBriefing] = [:]

    private static let cacheDir = "\(NSHomeDirectory())/.claude/hud/project-briefings"
    private static let maxCacheAge: TimeInterval = 24 * 3600 // 24 hours

    /// Path to the claude CLI
    private var claudePath: String {
        let paths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude"
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "claude"
    }

    init() {
        ensureCacheDir()
        loadAllCached()
    }

    func generateBriefing(for project: Project) {
        // Already loading or have a fresh cached version
        if let existing = briefings[project.id] {
            if existing.isLoading { return }
            if existing.error == nil && Date().timeIntervalSince(existing.generatedAt) < Self.maxCacheAge {
                return
            }
        }

        // Show cached content while refreshing (if stale but exists)
        if briefings[project.id] == nil {
            briefings[project.id] = ProjectBriefing(
                id: project.id,
                summary: "",
                status: "",
                priorities: [],
                blockers: [],
                nextActions: [],
                isLoading: true
            )
        } else {
            // Keep showing stale data but mark as loading
            briefings[project.id]?.isLoading = true
        }

        let context = gatherContext(for: project)
        let cliPath = claudePath
        let projectId = project.id
        let projectName = project.name

        Task.detached(priority: .userInitiated) {
            let result = await Self.runClaude(context: context, projectName: projectName, claudePath: cliPath)
            if result.error == nil {
                Self.saveToDisk(projectId: projectId, briefing: result)
            }
            await MainActor.run { [weak self] in
                self?.briefings[projectId] = result
            }
        }
    }

    func invalidate(projectId: String) {
        briefings.removeValue(forKey: projectId)
        Self.deleteFromDisk(projectId: projectId)
    }

    func invalidateAll() {
        briefings.removeAll()
        // Clear cache dir
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: Self.cacheDir) {
            for file in files {
                try? fm.removeItem(atPath: "\(Self.cacheDir)/\(file)")
            }
        }
    }

    // MARK: - Disk Cache

    private func ensureCacheDir() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.cacheDir) {
            try? fm.createDirectory(atPath: Self.cacheDir, withIntermediateDirectories: true)
        }
    }

    private func loadAllCached() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.cacheDir) else { return }

        for file in files where file.hasSuffix(".json") {
            let path = "\(Self.cacheDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let cached = try? JSONDecoder().decode(CachedBriefing.self, from: data) else { continue }

            briefings[cached.briefing.id] = cached.briefing
        }
        logger.info("Loaded \(self.briefings.count) cached project briefings")
    }

    nonisolated private static func saveToDisk(projectId: String, briefing: ProjectBriefing) {
        let cached = CachedBriefing(briefing: briefing, generatedAt: Date())
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let safeName = projectId.replacingOccurrences(of: "/", with: "_")
        let path = "\(cacheDir)/\(safeName).json"
        FileManager.default.createFile(atPath: path, contents: data)
    }

    nonisolated private static func deleteFromDisk(projectId: String) {
        let safeName = projectId.replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.removeItem(atPath: "\(cacheDir)/\(safeName).json")
    }

    // MARK: - Context Gathering

    private func gatherContext(for project: Project) -> String {
        var parts: [String] = []

        // Obsidian notes content
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: project.obsidianPath) {
            for file in files.sorted() where file.hasSuffix(".md") {
                let path = "\(project.obsidianPath)/\(file)"
                if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    let name = String(file.dropLast(3))
                    let truncated = String(content.prefix(3000))
                    parts.append("## Obsidian Note: \(name)\n\(truncated)")
                }
            }
        }

        // Recent session previews
        if !project.recentSessions.isEmpty {
            var sessionBlock = "## Recent Claude Sessions\n"
            for session in project.recentSessions {
                sessionBlock += "- \(session.timestamp.relativeString): \(session.preview)\n"
            }
            parts.append(sessionBlock)
        }

        // Today's calendar events
        if !project.upcomingEvents.isEmpty {
            var calBlock = "## Today's Calendar Events\n"
            for event in project.upcomingEvents {
                let fmt = DateFormatter()
                fmt.dateFormat = "h:mma"
                let time = fmt.string(from: event.startDate).lowercased()
                calBlock += "- \(time): \(event.title)"
                if !event.attendees.isEmpty {
                    calBlock += " (with \(event.attendees.map(\.name).joined(separator: ", ")))"
                }
                calBlock += "\n"
            }
            parts.append(calBlock)
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Claude Synthesis

    nonisolated private static func runClaude(context: String, projectName: String, claudePath: String) async -> ProjectBriefing {
        let prompt = """
        You are a project analyst. Based on the following context about the project "\(projectName)", \
        produce a brief project status briefing. Respond ONLY with valid JSON in this exact format, no markdown fencing:

        {"summary":"1-2 sentence overview of current project state","status":"one of: active, stalled, wrapping-up, starting","priorities":["priority 1","priority 2"],"blockers":["blocker 1"],"nextActions":["action 1","action 2"]}

        If a field has no items, use an empty array []. Be concise — each string should be one short sentence max.

        PROJECT CONTEXT:
        \(context)
        """

        // Use script(1) wrapper like ClaudeCLIClient does — avoids PTY buffering issues
        let args = [
            "-p", prompt,
            "--model", "haiku",
            "--output-format", "text",
            "--dangerously-skip-permissions",
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", claudePath] + args
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
                return errorBriefing(projectName, "No response from Claude")
            }

            // Clean PTY artifacts: strip ANSI escape codes, carriage returns, control chars
            let stripped = raw
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\\e\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\x1b\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)

            // Extract JSON object from anywhere in the output
            guard let jsonStart = stripped.firstIndex(of: "{"),
                  let jsonEnd = stripped.lastIndex(of: "}") else {
                logger.warning("No JSON found in briefing output: \(stripped.prefix(200))")
                return errorBriefing(projectName, "No JSON in response")
            }

            let jsonString = String(stripped[jsonStart...jsonEnd])

            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                logger.warning("Failed to parse briefing JSON: \(jsonString.prefix(200))")
                return errorBriefing(projectName, "Could not parse response")
            }

            return ProjectBriefing(
                id: projectName,
                summary: json["summary"] as? String ?? "",
                status: json["status"] as? String ?? "unknown",
                priorities: json["priorities"] as? [String] ?? [],
                blockers: json["blockers"] as? [String] ?? [],
                nextActions: json["nextActions"] as? [String] ?? [],
                isLoading: false
            )
        } catch {
            logger.error("Claude CLI error: \(error.localizedDescription)")
            return errorBriefing(projectName, error.localizedDescription)
        }
    }

    nonisolated private static func errorBriefing(_ id: String, _ message: String) -> ProjectBriefing {
        ProjectBriefing(
            id: id, summary: "", status: "", priorities: [], blockers: [], nextActions: [],
            isLoading: false, error: message
        )
    }
}
