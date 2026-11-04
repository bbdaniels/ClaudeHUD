import Foundation

// MARK: - Session Info Model

struct SessionInfo: Identifiable {
    let id: String           // session UUID (filename without .jsonl)
    let projectPath: String  // decoded absolute path, on this Mac (`SessionHost.macPath`)
    let projectName: String  // last component (e.g. "ClaudeHUD")
    let preview: String      // first user message preview
    let timestamp: Date      // file modification time (the iMac's own, for a mirrored transcript)
    let filePath: String     // full path to .jsonl file (for on-demand search)
    /// The machine the session ran on: the Mac's own transcript, or the
    /// iMac's, read from the mirror. Resume, delete and filing follow it.
    let host: SessionHost

    /// Worktree subdirectory name when this session lives under
    /// `<project>/.claude/worktrees/<name>/...`, otherwise nil.
    var worktreeName: String? {
        guard let range = projectPath.range(of: "/.claude/worktrees/") else { return nil }
        let after = projectPath[range.upperBound...]
        let name = after.split(separator: "/").first.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    func relabeled(_ preview: String) -> SessionInfo {
        SessionInfo(id: id, projectPath: projectPath, projectName: projectName, preview: preview,
                    timestamp: timestamp, filePath: filePath, host: host)
    }
}

/// A transcript's cached listing verdict, valid while the file's mtime and
/// size are unchanged. A machine one-shot is never listed; a listed session
/// with no `label` (no real user turn in its head) shows only when a title
/// sidecar exists for it.
struct CachedHead {
    enum Kind: String { case machine, listed }
    let mtime: Double
    let size: Int64
    let kind: Kind
    let label: String?
}

// MARK: - Session Scan

/// THE History scan: which transcripts are real sessions, and how each is
/// labeled. One scan over every host's transcript directory (the Mac's
/// `~/.claude/projects` and the iMac's mirror, `SessionHost.projectsDir`),
/// with one head classification, one title source and one decoder; the two
/// lists are merged and sorted newest first. Foundation only, so the tests
/// compile it directly.
enum SessionScan {

    struct Result {
        let sessions: [SessionInfo]
        let changedHeads: [String: CachedHead]
        let removedPaths: [String]
    }

    /// List real sessions on every host in `roots`. ~/.claude/projects holds
    /// ~10,000 transcripts (almost all machine one-shots, each in its own
    /// project dir), so re-reading every 64 KB head and decoding every dir
    /// name on each scan cost ~12 s. Head verdicts are cached by path + mtime
    /// + size (a transcript that has not changed cannot change verdict;
    /// mirrored transcripts are cached under their mirror paths), and a dir
    /// name is decoded only when it holds a listed session.
    ///
    /// A session id found on both hosts (a transcript copied from one machine
    /// to the other) is listed once: the copy whose file was modified later,
    /// which is where the session last ran; on a tie, the Mac's, which is
    /// local and can be deleted.
    static func scan(roots: [(host: SessionHost, dir: String)], headCache: [String: CachedHead],
                     sidecarTitles: [String: String], home: String = NSHomeDirectory()) -> Result {
        var changedHeads: [String: CachedHead] = [:]
        var seenPaths = Set<String>()
        var found: [SessionInfo] = []
        for root in roots {
            found += scanDir(root.dir, host: root.host, headCache: headCache, sidecarTitles: sidecarTitles,
                             home: home, changedHeads: &changedHeads, seenPaths: &seenPaths)
        }
        let removed = headCache.keys.filter { !seenPaths.contains($0) }
        return Result(sessions: merge(found), changedHeads: changedHeads, removedPaths: removed)
    }

    /// One row per session id (the later file wins, the Mac's on a tie),
    /// newest first.
    static func merge(_ sessions: [SessionInfo]) -> [SessionInfo] {
        var byId: [String: SessionInfo] = [:]
        for s in sessions {
            if let kept = byId[s.id] {
                let newer = s.timestamp > kept.timestamp
                let tieToMac = s.timestamp == kept.timestamp && s.host == .mac
                if !(newer || tieToMac) { continue }
            }
            byId[s.id] = s
        }
        return byId.values.sorted { $0.timestamp > $1.timestamp }
    }

    /// The sessions of one host's transcript directory.
    static func scanDir(_ baseDir: String, host: SessionHost, headCache: [String: CachedHead],
                        sidecarTitles: [String: String], home: String,
                        changedHeads: inout [String: CachedHead], seenPaths: inout Set<String>) -> [SessionInfo] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }

        var found: [SessionInfo] = []

        // mtime + size come back with the listing itself (bulk attribute
        // fetch), not one stat per transcript.
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for dir in projectDirs {
            let dirPath = "\(baseDir)/\(dir)"
            // Fails for non-directories, so no separate isDirectory stat.
            guard let urls = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dirPath, isDirectory: true),
                includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            var decodedDir: (path: String, name: String)?

            for url in urls where url.pathExtension == "jsonl" {
                let file = url.lastPathComponent
                let filePath = "\(dirPath)/\(file)"
                let sessionId = String(file.dropLast(6)) // remove .jsonl

                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modDate = values.contentModificationDate,
                      let fileSize = values.fileSize else { continue }
                let size = Int64(fileSize)
                seenPaths.insert(filePath)
                let mtime = modDate.timeIntervalSince1970

                // Classify every session from its transcript head FIRST — even
                // when a title sidecar exists. Sidecars used to win outright,
                // which let a machine one-shot that had been given a title
                // surface in history under a plausible one ("Skill-selection
                // query re: patient risk scoring"). The head read is off the
                // main thread and cached per file version.
                let verdict: CachedHead
                if let cached = headCache[filePath], cached.mtime == mtime, cached.size == size {
                    verdict = cached
                } else {
                    verdict = headVerdict(for: filePath, mtime: mtime, size: size)
                    changedHeads[filePath] = verdict
                }
                if verdict.kind == .machine { continue }

                if decodedDir == nil {
                    decodedDir = host == .iMac
                        ? iMacProjectDir(dir, transcript: filePath, home: home)
                        : decodeProjectDir(dir, host: host, home: home)
                }
                let (projectPath, projectName) = decodedDir!

                let preview: String
                if let title = sidecarTitles[sessionId] {
                    // A titled session: the sidecar title wins. Strip a
                    // leading "<project>: ", since every row already carries a
                    // project tag and old sidecars carry the prefix forever
                    // otherwise. A sidecar also rescues .unknown heads (e.g. a
                    // giant first record that overflows the head window): a
                    // title was only ever written for a session with substance.
                    preview = stripProjectPrefix(title, projectName: projectName)
                } else if let label = verdict.label {
                    preview = label
                } else {
                    // No real user turn found in the head and no title sidecar:
                    // abandoned shells and unparseable heads.
                    continue
                }

                found.append(SessionInfo(
                    id: sessionId,
                    projectPath: projectPath,
                    projectName: projectName,
                    preview: preview,
                    timestamp: modDate,
                    filePath: filePath,
                    host: host
                ))
            }
        }
        return found
    }

    /// Session titles, keyed by session id under
    /// ~/.claude/hud/session-titles/<id>.txt. `SessionTitler` is the only
    /// writer. The retired per-session vault digest also wrote sidecars here;
    /// those files still display, and nothing but `SessionTitler` writes new
    /// ones (the daily review that replaced the digest writes none). Loaded
    /// once per scan; an untitled session falls
    /// back to its first real prompt. A sidecar is a LABEL, not a listing
    /// decision: machine one-shots are dropped by TranscriptHead.classify even when a
    /// stray sidecar exists. Keyed by session id alone, so a session mirrored
    /// from the iMac is titled here on the Mac like any other.
    static func loadSidecarTitles(home: String = NSHomeDirectory()) -> [String: String] {
        let dir = "\(home)/.claude/hud/session-titles"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [:] }
        var map: [String: String] = [:]
        map.reserveCapacity(files.count)
        for f in files where f.hasSuffix(".txt") {
            let sid = String(f.dropLast(4))
            guard let raw = try? String(contentsOfFile: "\(dir)/\(f)", encoding: .utf8) else { continue }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { map[sid] = String(t.prefix(100)) }
        }
        return map
    }

    /// One session's title from its sidecar (the same file and the same
    /// project-prefix strip as `loadSidecarTitles` and the History row), for
    /// the few live sessions; nil when none is written.
    static func sidecarTitle(sessionId: String, projectName: String, home: String = NSHomeDirectory()) -> String? {
        guard let raw = try? String(contentsOfFile: "\(home)/.claude/hud/session-titles/\(sessionId).txt", encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : stripProjectPrefix(String(t.prefix(100)), projectName: projectName)
    }

    /// Strip a leading "<project>: " / "<project> — " from a sidecar title.
    /// The history row already carries a project tag, but sidecars left by
    /// the retired per-session vault digest, and the occasional model slip
    /// since, still carry the name. A display-level strip fixes the whole
    /// backlog without rewriting any file.
    static func stripProjectPrefix(_ title: String, projectName: String) -> String {
        guard !projectName.isEmpty, title.count > projectName.count,
              title.lowercased().hasPrefix(projectName.lowercased()) else { return title }
        let rest = title.dropFirst(projectName.count)
        guard let sep = rest.first, ":—–- ".contains(sep) else { return title }
        let stripped = rest.drop { ":—–- ".contains($0) }
        guard stripped.count >= 8 else { return title }  // never strip to a stub
        return stripped.prefix(1).uppercased() + String(stripped.dropFirst())
    }

    // MARK: - Project Path Decoding

    /// An iMac transcript's directory on this Mac. The decoder resolves an
    /// ambiguous "-" by asking this Mac's disk, which cannot see a directory
    /// that exists only on the iMac (a worktree, `.claude/worktrees/<name>`,
    /// or a folder whose name starts with a dot): those would decode to a
    /// folder the iMac does not have, and resume there would be refused. So
    /// the transcript's own records are read for the directory the folder is
    /// named after (`recordedDirectory`), which is mapped onto this Mac
    /// (`SessionHost.macPath`); the decoder is the fallback.
    static func iMacProjectDir(_ dirName: String, transcript: String,
                               home: String = NSHomeDirectory()) -> (path: String, name: String) {
        if let cwd = recordedDirectory(named: dirName, in: transcript) {
            let path = SessionHost.iMac.macPath(cwd, home: home)
            return (path, URL(fileURLWithPath: path).lastPathComponent)
        }
        return decodeProjectDir(dirName, host: .iMac, home: home)
    }

    /// The first working directory a transcript records whose Claude Code
    /// encoding is `dirName`, the name of the folder holding the transcript.
    /// Usually the first record's. A session started with `--worktree`
    /// records its main checkout first and the worktree, which names the
    /// folder, only once the worktree is made (about 500 KB in, in one
    /// transcript of 2026-11-03), so the read goes on past the head, a
    /// chunk at a time, stopping at the first match or at `limit` bytes.
    static func recordedDirectory(named dirName: String, in path: String, limit: Int = 4 << 20) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        var carry = Data()
        var read = 0
        while read < limit {
            let chunk = handle.readData(ofLength: 256 << 10)
            if chunk.isEmpty { break }
            read += chunk.count
            carry.append(chunk)
            // Complete lines only; the tail waits for the next chunk.
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            for line in carry[..<lastNewline].split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let cwd = TranscriptRecord.cwd(inLine: line), SessionHost.encodeDirName(cwd) == dirName {
                    return cwd
                }
            }
            carry = Data(carry[(lastNewline + 1)...])
        }
        return nil
    }

    /// Decode a directory name like `-Users-bbdaniels-GitHub-ClaudeHUD` back to `/Users/bbdaniels/GitHub/ClaudeHUD`.
    ///
    /// Claude Code encodes project paths by replacing `/`, `_`, and `.` with `-`.
    /// Decoding is ambiguous, so we probe the filesystem greedily: at each `-`,
    /// try treating it as a path separator (checking dash, underscore, and dot
    /// variants of the accumulated component). If no directory matches, keep the
    /// dash as a literal character in the current component.
    ///
    /// An iMac directory reaches the decoder only when its transcript does not
    /// name its start directory (`iMacProjectDir`). One under its `~/Projects` is first renamed to the name
    /// the Mac gives the same directory (`SessionHost.macDirName`) and decoded
    /// against the Mac's own checkouts, so its path is this Mac's. Any other
    /// iMac directory is left as the iMac's path, decoded without probing:
    /// this Mac's disk says nothing about the iMac's, so each "-" after the
    /// iMac's home stays literal.
    static func decodeProjectDir(_ dirName: String, host: SessionHost = .mac,
                                 home: String = NSHomeDirectory()) -> (path: String, name: String) {
        if host == .iMac {
            if let macName = host.macDirName(dirName, home: home) {
                return decodeProjectDir(macName, host: .mac, home: home)
            }
            let iMacHome = SessionHost.iMacHome
            let encodedHome = SessionHost.encodeDirName(iMacHome)
            let path: String
            if dirName == encodedHome {
                path = iMacHome
            } else if dirName.hasPrefix(encodedHome + "-") {
                path = iMacHome + "/" + dirName.dropFirst(encodedHome.count + 1)
            } else {
                path = "/" + dirName.dropFirst().replacingOccurrences(of: "-", with: "/")
            }
            return (path, URL(fileURLWithPath: path).lastPathComponent)
        }
        let fm = FileManager.default
        // "/Users/bbdaniels" → "-Users-bbdaniels", by Claude Code's own
        // encoding (every character not an ASCII letter or digit is "-"), the
        // one `SessionHost.macDirName` writes for an iMac directory.
        let homeEncoded = SessionHost.encodeDirName(home)

        let basePath: String
        let remainder: String

        if dirName.hasPrefix(homeEncoded + "-") {
            basePath = home
            remainder = String(dirName.dropFirst(homeEncoded.count + 1))
        } else {
            basePath = ""
            remainder = String(dirName.dropFirst(1))
        }

        var resolved = basePath
        var component = ""

        for c in remainder {
            if c == "-" {
                if !component.isEmpty {
                    // Try treating this dash as a path separator
                    for variant in componentVariants(component) {
                        let candidate = resolved + "/" + variant
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                            resolved = candidate
                            component = ""
                            break
                        }
                    }
                    if component.isEmpty { continue }
                }
                // Not a separator — keep as literal dash (may represent '-', '_', or '.')
                component.append("-")
            } else {
                component.append(c)
            }
        }

        // Resolve the final component (file or directory)
        if !component.isEmpty {
            for variant in componentVariants(component) {
                let candidate = resolved + "/" + variant
                if fm.fileExists(atPath: candidate) {
                    return (candidate, variant)
                }
            }
        }

        let fallbackPath = component.isEmpty ? resolved : resolved + "/" + component
        return (fallbackPath, URL(fileURLWithPath: fallbackPath).lastPathComponent)
    }

    /// Returns variants of a path component, trying all combinations of dash/space/underscore/dot
    /// at each dash position.  Handles names like "26-1 Spring" where some dashes are literal and
    /// others represent spaces.  Falls back to uniform replacement when there are too many dashes.
    static func componentVariants(_ component: String) -> [String] {
        guard component.contains("-") else { return [component] }

        let parts = component.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let dashCount = parts.count - 1

        // Too many dashes for combinatorial search → uniform replacement only
        guard dashCount <= 4 else {
            return [
                component,
                component.replacingOccurrences(of: "-", with: " "),
                component.replacingOccurrences(of: "-", with: "_"),
                component.replacingOccurrences(of: "-", with: "."),
            ]
        }

        let separators = ["-", " ", "_", "."]
        let total = Int(pow(4.0, Double(dashCount)))
        var results: [String] = []
        results.reserveCapacity(total)

        for i in 0..<total {
            var result = parts[0]
            var combo = i
            for j in 1..<parts.count {
                result += separators[combo % 4] + parts[j]
                combo /= 4
            }
            results.append(result)
        }

        return results
    }

    /// A transcript's listing verdict: its head class resolved to a label.
    /// Expensive (a 64 KB head read, plus up to 1 MB for a magic launch), so
    /// the scan caches it per file version.
    static func headVerdict(for path: String, mtime: Double, size: Int64) -> CachedHead {
        switch TranscriptHead.classify(path: path) {
        case .machine:
            return CachedHead(mtime: mtime, size: size, kind: .machine, label: nil)
        case .unknown:
            return CachedHead(mtime: mtime, size: size, kind: .listed, label: nil)
        case .normal(let firstPrompt):
            return CachedHead(mtime: mtime, size: size, kind: .listed, label: firstPrompt)
        case .magicLaunch:
            // Claude Code's ai-title is generated from the opening turn and
            // FROZEN, and every magic-launched session opens with the same
            // bootstrap boilerplate, so its ai-title is always junk ("context
            // load", "obsidian estonia-ecm project") no matter the work that
            // followed. Label with the user's first real prompt instead. A
            // bootstrap the person never typed into is an abandoned shell,
            // listed only if a title sidecar exists for it (like .unknown).
            return CachedHead(mtime: mtime, size: size, kind: .listed, label: conversationOpening(in: path, promptLimit: 1, wantReply: false).prompts.first.map { String($0.prefix(100)) })
        }
    }

    /// The opening of the conversation as the person had it: their first
    /// `promptLimit` genuine prompts (after any magic-launch bootstrap) and
    /// the first assistant text that followed the first one. Bootstrap
    /// context loading can run past a megabyte, so the file is streamed in
    /// chunks until enough is found. Only records the person sent count
    /// (`TranscriptRecord.humanTurnMarkers`: a terminal's typed, queued or
    /// accepted-suggestion turns, and any surface's `turnOrigin: "human"`,
    /// which is how the phone's and the desktop app's turns read);
    /// system-injected records (task notifications) and meta/skill
    /// expansions carry neither. Read-only.
    static func conversationOpening(in path: String, promptLimit: Int, wantReply: Bool)
        -> (prompts: [String], reply: String?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], nil) }
        defer { handle.closeFile() }

        let sources = TranscriptRecord.humanTurnMarkers
        let assistantMarker = Data("\"type\":\"assistant\"".utf8)
        var prompts: [String] = []
        var reply: String?
        func done() -> Bool { prompts.count >= promptLimit && (!wantReply || reply != nil) }

        var pending = Data()
        while true {
            let chunk = handle.readData(ofLength: 1_048_576)
            let atEOF = chunk.isEmpty
            pending.append(chunk)
            // Complete lines only; keep a trailing partial line for the next chunk.
            let end = atEOF ? pending.endIndex : (pending.lastIndex(of: 0x0A).map { pending.index(after: $0) } ?? pending.startIndex)
            let complete = pending[pending.startIndex..<end]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let isPrompt = prompts.count < promptLimit && sources.contains(where: { line.range(of: $0) != nil })
                let isReply = wantReply && reply == nil && !prompts.isEmpty && line.range(of: assistantMarker) != nil
                guard isPrompt || isReply,
                      let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let role = TranscriptRecord.role(from: json),
                      let content = TranscriptRecord.messageContent(from: json)
                else { continue }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }

                if isReply, role == "assistant" {
                    reply = String(trimmed.prefix(400))
                } else if isPrompt, role == "user" {
                    if TranscriptHead.magicLaunchProject(trimmed) != nil || TranscriptHead.isPassThroughPrompt(trimmed) { continue }
                    if trimmed.hasPrefix("Caveat: The messages below") { continue }  // local-command caveat
                    if trimmed.hasPrefix("[Request interrupted") { continue }        // interrupt sentinel
                    prompts.append(String(trimmed.prefix(300)))
                }
                if done() { return (prompts, reply) }
            }
            if atEOF { return (prompts, reply) }
            pending = Data(pending[end...])
        }
    }
}
