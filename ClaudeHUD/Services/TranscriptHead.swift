import Foundation

// MARK: - Transcript Records

/// Reading one record (one JSONL line) of a Claude Code transcript: its role,
/// its text, whether a person sent it, and the directory it ran in.
/// Foundation-only, so the unit tests compile it directly; the history scan,
/// the titler and the search index all read records through it.
enum TranscriptRecord {

    /// Extract user/assistant text content from a JSONL line (any format).
    static func messageContent(from json: [String: Any]) -> String? {
        // Format 1: {"role": "user"/"assistant", "content": "..."}
        if let role = json["role"] as? String, role == "user" || role == "assistant" {
            return textContent(json["content"])
        }
        // Format 2: {"type": "human"/"assistant", "message": {...}}
        if let type = json["type"] as? String, (type == "human" || type == "assistant") {
            if let msg = json["message"] as? [String: Any] {
                return textContent(msg["content"])
            }
        }
        // Format 3: {"message": {"role": "user"/"assistant", ...}}
        if let msg = json["message"] as? [String: Any],
           let role = msg["role"] as? String, role == "user" || role == "assistant" {
            return textContent(msg["content"])
        }
        return nil
    }

    /// Get the role from a JSONL message line.
    static func role(from json: [String: Any]) -> String? {
        if let role = json["role"] as? String { return role }
        if let type = json["type"] as? String {
            if type == "human" { return "user" }
            if type == "assistant" { return "assistant" }
        }
        if let msg = json["message"] as? [String: Any],
           let role = msg["role"] as? String { return role }
        return nil
    }

    /// Extract text from content that may be a string or an array of content blocks.
    static func textContent(_ content: Any?) -> String? {
        if let str = content as? String, !str.isEmpty {
            return str
        }
        // Every text block, joined: a message can carry several, and search
        // must see all of them. Tool payloads (tool_use / tool_result) and
        // thinking blocks are not text and are skipped.
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let text = block["text"] as? String, !text.isEmpty else { return nil }
                return text
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    /// True when a person sent this user record. Claude Code stamps
    /// `turnOrigin: "human"` on every turn a person typed, whichever surface
    /// they typed it in, and `clientPlatform` (for example "ios") on turns
    /// that came through Remote Control from the Claude app. A session the
    /// phone started runs as a `--print` child of `claude remote-control`, so
    /// its records carry `entrypoint: "sdk-cli"` and `promptSource: "sdk"`
    /// like a programmatic one-shot; these two fields are what tell them apart.
    static func isHumanTurn(_ json: [String: Any]) -> Bool {
        json["turnOrigin"] as? String == "human" || json["clientPlatform"] != nil
    }

    /// True when another Claude session injected this record (a
    /// cross-session message). A peer turn is never the person's own work.
    static func isPeerTurn(_ json: [String: Any]) -> Bool {
        json["turnOrigin"] as? String == "peer"
    }

    /// A line that is a turn a person sent: the byte test the titler uses to
    /// find prompts without parsing every record. The `promptSource` values
    /// mark turns typed in a terminal (typed, queued while Claude was busy,
    /// an accepted suggestion); `turnOrigin: "human"` marks every surface,
    /// including the phone and the desktop app, whose turns read
    /// `promptSource: "sdk"`.
    static let humanTurnMarkers: [Data] =
        ["\"promptSource\":\"typed\"", "\"promptSource\":\"queued\"",
         "\"promptSource\":\"suggestion_accepted\"", "\"turnOrigin\":\"human\""]
            .map { Data($0.utf8) }

    private static let cwdMarker = Data("\"cwd\":\"".utf8)

    /// The working directory a record ran in, read from its bytes without
    /// parsing the record. Claude Code writes the record's own `cwd` field
    /// after its payload, so the LAST `"cwd":"` in the line is the record's
    /// (an earlier one can sit inside an attachment's context). A value with
    /// an escape in it is decoded as a JSON string.
    static func cwd<D: DataProtocol>(inLine line: D) -> String? {
        let bytes = Data(line)
        guard let marker = bytes.range(of: cwdMarker, options: .backwards) else { return nil }
        var end = marker.upperBound
        var escaped = false
        var sawEscape = false
        while end < bytes.endIndex {
            let b = bytes[end]
            if escaped { escaped = false } else if b == 0x5C { escaped = true; sawEscape = true } else if b == 0x22 { break }
            end += 1
        }
        guard end < bytes.endIndex, end > marker.upperBound else { return nil }
        let raw = bytes[marker.upperBound..<end]
        if !sawEscape { return String(data: raw, encoding: .utf8) }
        let quoted = Data([0x22]) + raw + Data([0x22])
        return (try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed)) as? String
    }

    /// Add one to `counts` for each record in `data` (complete JSONL lines)
    /// that names a working directory.
    static func tallyCwds<D: DataProtocol>(in data: D, into counts: inout [String: Int])
        where D.SubSequence == D {
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let cwd = cwd(inLine: line), !cwd.isEmpty { counts[cwd, default: 0] += 1 }
        }
    }
}

// MARK: - Head Classification

/// What the head of a transcript says about a session: listed in history
/// under a label, or a programmatic run that is never listed.
enum TranscriptHead {

    /// What the head of a transcript says about a session. `.normal` carries
    /// the first genuine user prompt (preview-ready); `.magicLaunch` the
    /// project name parsed from the bootstrap boilerplate; `.machine` is a
    /// programmatic one-shot (never listed); `.unknown` means the head held
    /// no verdict (listed only if a title sidecar vouches for it).
    enum Verdict: Equatable {
        case machine
        case unknown
        case normal(String)
        case magicLaunch(String)
    }

    /// The first window `classify(path:)` reads, and the most it reads.
    static let headWindow = 64 << 10
    static let headLimit = 4 << 20

    /// Classify a session from the head of its transcript: the first
    /// `headWindow` bytes, widened fourfold while the head holds no verdict,
    /// up to `headLimit`. Only whole lines are classified, so a record cut at
    /// the window's edge is never half read (a cut inside a multibyte
    /// character also made the whole head undecodable). Before 2026-11-05 the
    /// head was a fixed 64 KB: a continued session whose carried-over
    /// attachments fill that window before its first prompt (48 KB and 55 KB
    /// records in two that day) read as `.unknown`, so history dropped it,
    /// the titler, which takes its sessions from history, never named it,
    /// and its live row kept its starting name.
    static func classify(path: String) -> Verdict {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { handle.closeFile() }
        var data = Data()
        var window = headWindow
        while true {
            data.append(handle.readData(ofLength: window - data.count))
            let atEnd = data.count < window
            let whole = atEnd ? data : data[..<(data.lastIndex(of: 0x0A) ?? data.endIndex)]
            guard let text = String(data: whole, encoding: .utf8) else { return .unknown }
            let verdict = classify(text: text)
            if verdict == .unknown, !atEnd, window < headLimit {
                window = min(window * 4, headLimit)
                continue
            }
            return verdict
        }
    }

    /// Classify a session from the text of its transcript's head.
    ///
    ///  * **.machine**: programmatic `claude -p` runs: skill-tip catalog
    ///    selectors, remote-control liveness probes (PONG / SMOKE_OK), old
    ///    runs of the retired per-session vault digest. Detected
    ///    STRUCTURALLY: an SDK one-shot's user record carries
    ///    `entrypoint: "sdk-cli"`, while a terminal, VSCode, magic-launch or
    ///    background session records "cli"-family entrypoints. Prompt-prefix
    ///    checks cover old transcripts that predate the field.
    ///
    ///  * A turn a person sent (`TranscriptRecord.isHumanTurn`) is exempt
    ///    from both SDK tests. Since 2026-11-03 this keeps the sessions Ben
    ///    starts from the Claude iOS app through Remote Control, which run as
    ///    `--print` children of `claude remote-control` and so read
    ///    "sdk-cli" on every record, and the sessions of the desktop app,
    ///    whose turns read `promptSource: "sdk"`. Both carry
    ///    `turnOrigin: "human"`; a genuine one-shot never does.
    ///
    ///  * A peer turn (another session's injected message) and a meta record
    ///    (a skill or command expansion) are never the person's prompt. A
    ///    peer turn counts as machine evidence, so a session that only ever
    ///    received peer messages is dropped.
    ///
    ///    A `promptSource: "sdk"` record alone is NOT condemning: a real
    ///    interactive session can carry an injected selector prompt as its
    ///    FIRST user record yet hold the person's typed work after it
    ///    (observed in the wild: 1 of 7,617 transcripts). Such records are
    ///    skipped; `<command>` wrappers count as interactive evidence; only
    ///    if sdk records were seen and nothing interactive followed does the
    ///    window end as .machine.
    static func classify(text: String) -> Verdict {
        var sawSdk = false
        var sawLive = false
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            guard let content = TranscriptRecord.messageContent(from: json),
                  let role = TranscriptRecord.role(from: json), role == "user" else { continue }

            // Human-driven RELAY sessions run as SDK processes (entrypoint
            // "sdk-cli") yet are a person's real work: the ClaudeHUD Slack
            // relay stamps its context preamble onto the first user message.
            // Match the marker BEFORE the sdk-cli drop or every Slack session
            // vanishes from history. Title = the user's own text after the
            // preamble.
            if content.hasPrefix("[ClaudeHUD Slack session.") {
                let body = content.range(of: "User message: ")
                    .map { String(content[$0.upperBound...]) } ?? content
                let title = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return .normal(title.isEmpty ? "Slack session" : String(title.prefix(100)))
            }
            let human = TranscriptRecord.isHumanTurn(json)
            if !human {
                if TranscriptRecord.isPeerTurn(json) { sawSdk = true; continue }
                if json["isMeta"] as? Bool == true { continue }
                if json["entrypoint"] as? String == "sdk-cli" { return .machine }
                if json["promptSource"] as? String == "sdk" { sawSdk = true; continue }
            }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            // Magic-launch bootstrap is delivered as the `/project`
            // slash command, whose recorded first turn starts with the
            // `<command-name>…` wrapper, so it must be recognised BEFORE the
            // generic `<`-wrapper skip below, or it would be swallowed as a
            // pass-through and the session mislabelled as normal.
            if let project = magicLaunchProject(trimmed) {
                return .magicLaunch(project)
            }
            // Command/skill wrappers precede the real prompt in real
            // sessions: skip the MESSAGE, note the interactive evidence,
            // keep scanning.
            if isPassThroughPrompt(trimmed) { sawLive = true; continue }
            // Known machine first-prompts drop the SESSION.
            if isMachineFirstPrompt(trimmed) { return .machine }
            return .normal(String(trimmed.prefix(100)))
        }

        return (sawSdk && !sawLive) ? .machine : .unknown
    }

    /// Synthetic user messages that are commands passed through to Claude,
    /// not the user's actual topic: they precede the real prompt in a real
    /// session, so the scan skips past them. Explicit prefix (not a broad
    /// heuristic) so real prompts are never hidden.
    static func isPassThroughPrompt(_ s: String) -> Bool {
        s.hasPrefix("<")  // <command>/<skill>/<local-command-caveat> wrappers
    }

    /// First prompts that mark the whole SESSION as machine-generated: a
    /// programmatic one-shot, not the user's work. The structural sdk-cli
    /// check in `classify` catches the modern ones; these prefixes cover
    /// transcripts that predate the entrypoint/promptSource fields. Extend
    /// as new probe forms appear.
    static func isMachineFirstPrompt(_ s: String) -> Bool {
        if s.hasPrefix("You select the single most relevant skill") { return true }  // skill-tip catalog selector
        if s.hasPrefix("# Session Ingest") { return true }                           // old transcripts of the retired per-session vault digest
        if s.hasPrefix("<!-- === Managed by ClaudeHUD") { return true }              // managed-prompt pipelines
        if s.hasPrefix("Reply with exactly") { return true }                         // liveness probes ("…the word: PONG", "…: SMOKE_OK")
        if s.hasPrefix("Return ONLY this JSON object") { return true }               // remote-control JSON echo probe
        return false
    }

    /// Project name carried by a magic-launch bootstrap, or nil if the message
    /// isn't one. The bootstrap is delivered as the `/project` slash command
    /// (`/vault-bootstrap` before 2026-10-25; see `magicLaunchArg` in
    /// HUDContentView + the command file at ~/.claude/commands/project.md). Handles both ways Claude Code
    /// may record that first turn: the usual `<command-name>/vault-bootstrap
    /// </command-name>…<command-args>…</command-args>` wrapper, and a raw
    /// `/vault-bootstrap <args>` line (fallback). The args are `<project>`
    /// optionally followed by ` :: <resolvedVaultPath>`; the project is the
    /// text before ` :: `. Recognising this lets history relabel these
    /// sessions by project + real prompt instead of the bootstrap boilerplate.
    ///
    /// The wrapper is matched ANYWHERE in the message, not at its start: Claude
    /// Code emits `<command-message>vault-bootstrap</command-message>` on the
    /// line ABOVE `<command-name>`, so a prefix test never fires on a real
    /// transcript (verified against one). That miss was invisible rather than
    /// loud: the message still begins with `<`, so `isPassThroughPrompt`
    /// swallowed it and the session was labelled `.normal` off the user's
    /// second message, which is exactly what recognising it here prevents.
    static func magicLaunchProject(_ s: String) -> String? {
        // `/project` since 2026-10-25; older transcripts carry `/vault-bootstrap`.
        for command in ["project", "vault-bootstrap"] {
            if let nameTag = s.range(of: "<command-name>/\(command)</command-name>") {
                guard let open = s.range(of: "<command-args>", range: nameTag.upperBound..<s.endIndex),
                      let close = s.range(of: "</command-args>", range: open.upperBound..<s.endIndex)
                else { return nil }
                return projectName(fromArgs: String(s[open.upperBound..<close.lowerBound]))
            }
            let raw = "/\(command)"
            if s == raw || s.hasPrefix(raw + " ") || s.hasPrefix(raw + "\n") {
                return projectName(fromArgs: String(s.dropFirst(raw.count)))
            }
        }
        return nil
    }

    static func projectName(fromArgs args: String) -> String? {
        var name = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sep = name.range(of: " :: ") { name = String(name[..<sep.lowerBound]) }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
