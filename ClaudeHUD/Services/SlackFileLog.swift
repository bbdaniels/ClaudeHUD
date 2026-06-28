import Foundation

/// Tiny append-only file logger for the Slack integration, mirroring the
/// os_log/Logger calls to a readable file at `~/Library/Logs/claudehud-slack.log`.
///
/// Exists because the hardened-runtime app's unified-log output is not always
/// readable in the dev/debug environment; a plain file is. Lines are
/// timestamped and appended (the file is never truncated). NEVER pass token
/// values or other secrets to `log` — only presence flags, ids, statuses.
enum SlackFileLog {
    private static let queue = DispatchQueue(label: "com.claudehud.slack.filelog")

    private static let fileURL: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return logs.appendingPathComponent("claudehud-slack.log")
    }()

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Append one timestamped line. Serialized on a private queue and safe to
    /// call from any thread/actor.
    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            let dir = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
