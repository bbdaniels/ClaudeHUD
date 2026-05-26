import SwiftUI
import AppKit

/// Native "Agents" tab: a live view of the Claude Code daemon's background
/// sessions with the documented management verbs. Mirrors `claude agents`
/// without taking over a terminal. Attach opens the session in a terminal tab.
struct AgentsView: View {
    @EnvironmentObject var service: AgentsService
    @EnvironmentObject var terminalService: TerminalService
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @Environment(\.fontScale) private var scale

    @State private var dispatchPrompt = ""
    @State private var dispatchName = ""
    @State private var dispatchDir: String?
    @State private var dispatchDirLabel = "Target…"
    @State private var pendingRemoval: AgentSession?
    @State private var logsAgent: AgentSession?
    @State private var logsText = ""
    @State private var loadingLogs = false
    /// Low-signal buckets start collapsed (drop-down to expand), same idiom
    /// as Session History's TimeSectionView. Keyed by group title.
    @State private var collapsedGroups: Set<String> = ["Completed", "Detached"]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)
            list
        }
        .onAppear {
            service.start()
            if sessionHistory.sessions.isEmpty { Task { await sessionHistory.refresh() } }
        }
        .confirmationDialog(
            "Remove agent \u{201C}\(pendingRemoval?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove (deletes its worktree)", role: .destructive) {
                if let a = pendingRemoval { service.remove(a.id) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("`claude rm` removes the session and cleans up its git worktree, including uncommitted changes there. The transcript stays on disk.")
        }
        .sheet(item: $logsAgent) { a in logsSheet(a) }
    }

    // MARK: - Toolbar (dispatch + refresh)

    private var toolbar: some View {
        HStack(spacing: 6) {
            TextField("New task...", text: $dispatchPrompt)
                .font(.smallFont(scale))
                .textFieldStyle(.plain)
                .onSubmit(sendDispatch)
            TextField("name", text: $dispatchName)
                .font(.smallFont(scale))
                .textFieldStyle(.plain)
                .frame(width: 70 * scale)
                .opacity(dispatchPrompt.isEmpty ? 0.4 : 1)

            Menu {
                ForEach(dispatchTargets, id: \.path) { t in
                    Button(t.label) { dispatchDir = t.path; dispatchDirLabel = t.label }
                }
                Divider()
                Button("Choose folder…") { chooseFolder() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 10 * scale))
                    if dispatchDir != nil {
                        Text(dispatchDirLabel)
                            .font(.system(size: 10 * scale))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8 * scale))
                }
                .foregroundColor(dispatchDir == nil ? .secondary : .accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(dispatchDir.map { "Dispatch into \($0)" } ?? "Pick the project/folder the new agent runs in")

            Button(action: sendDispatch) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11 * scale))
                    .foregroundColor(canDispatch ? .accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canDispatch)
            .help(dispatchDir == nil ? "Pick a target folder first" : "Dispatch (claude --bg in \(dispatchDirLabel))")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.textBackgroundColor).opacity(0.3))
    }

    private var canDispatch: Bool {
        dispatchDir != nil && dispatchPrompt.trimmingCharacters(in: .whitespaces).count >= 4
    }

    /// Every directory Claude has actually run in, from session history —
    /// the same source the History tab uses. Worktree paths are normalized
    /// back to their repo root, deduped, most-recently-used first.
    private var dispatchTargets: [(label: String, path: String)] {
        var seen = Set<String>()
        var out: [(label: String, path: String)] = []
        for s in sessionHistory.sessions.sorted(by: { $0.timestamp > $1.timestamp }) {
            var dir = s.projectPath
            if let r = dir.range(of: "/.claude/worktrees/") { dir = String(dir[..<r.lowerBound]) }
            guard !dir.isEmpty, !seen.contains(dir) else { continue }
            seen.insert(dir)
            out.append((URL(fileURLWithPath: dir).lastPathComponent, dir))
            if out.count >= 25 { break }
        }
        return out
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Dispatch here"
        if panel.runModal() == .OK, let url = panel.url {
            dispatchDir = url.path
            dispatchDirLabel = url.lastPathComponent
        }
    }

    private func sendDispatch() {
        guard let dir = dispatchDir,
              dispatchPrompt.trimmingCharacters(in: .whitespaces).count >= 4 else { return }
        service.dispatch(prompt: dispatchPrompt, name: dispatchName, directory: dir)
        dispatchPrompt = ""; dispatchName = ""
    }

    // MARK: - List

    private var groups: [(title: String, items: [AgentSession])] {
        var order: [String] = []
        var bucket: [String: [AgentSession]] = [:]
        for a in service.agents {
            let t = a.isPinned ? "Pinned" : a.bucket.groupTitle
            if bucket[t] == nil { order.append(t); bucket[t] = [] }
            bucket[t]?.append(a)
        }
        return order.map { ($0, bucket[$0] ?? []) }
    }

    @ViewBuilder
    private var list: some View {
        if service.agents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 26 * scale))
                    .foregroundColor(.secondary)
                Text("No background agents")
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
                Text(service.lastError ?? "Dispatch one above, or launch from a project.")
                    .font(.system(size: 10 * scale))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.title) { group in
                        let isCollapsed = collapsedGroups.contains(group.title)
                        Section {
                            if !isCollapsed {
                                ForEach(group.items) { agent in
                                    AgentRow(agent: agent, scale: scale,
                                             onAttach: { attach(agent) },
                                             onStop: { service.stop(agent.id) },
                                             onRespawn: { service.respawn(agent.id) },
                                             onRemove: { pendingRemoval = agent },
                                             onLogs: { showLogs(agent) })
                                    Divider().opacity(0.15)
                                }
                            }
                        } header: {
                            HStack(spacing: 4) {
                                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9 * scale, weight: .semibold))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text(group.title.uppercased())
                                    .font(.system(size: 9 * scale, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(group.items.count)")
                                    .font(.system(size: 9 * scale))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if isCollapsed { collapsedGroups.remove(group.title) }
                                    else { collapsedGroups.insert(group.title) }
                                }
                            }
                            .hudTip(isCollapsed ? "Expand section" : "Collapse section")
                        }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let t = service.lastRefresh {
                    Text("updated \(relative(t))")
                        .font(.system(size: 8 * scale))
                        .foregroundColor(.secondary)
                        .padding(6)
                }
            }
        }
    }

    // MARK: - Actions

    private func attach(_ a: AgentSession) {
        // If we know which Ghostty process is currently hosting
        // `claude attach <id>`, raise its window directly — no title
        // guessing. Two unrelated shorts can share a project name, so the
        // old "match a window whose title contains the project" trick
        // routed clicks to the wrong session.
        if let pid = a.attachedGhosttyPid,
           let win = GhosttyWindowService.openWindows().first(where: { $0.pid == pid }) {
            GhosttyWindowService.raise(win)
            return
        }
        // Attached in a non-Ghostty terminal (no Ghostty pid) — best we can
        // do is activate the process; fall through to a fresh attach if
        // even that's not knowable.
        if a.isOpen, let pid = a.attachedGhosttyPid {
            NSRunningApplication(processIdentifier: pid)?.activate()
            return
        }
        // Truly detached — spawn a new attached window in the session's cwd.
        let dir = a.cwd.isEmpty ? nil : a.cwd
        _ = terminalService.launchWithCommand("claude attach \(a.id)", inDirectory: dir)
    }

    private func showLogs(_ a: AgentSession) {
        logsAgent = a
        logsText = ""
        loadingLogs = true
        Task {
            let out = await service.fetchLogs(a.id)
            await MainActor.run {
                logsText = out.isEmpty ? "(no output)" : out
                loadingLogs = false
            }
        }
    }

    private func logsSheet(_ a: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs · \(a.name)")
                    .font(.custom("Fira Sans", size: 12).weight(.semibold))
                Spacer()
                Button("Attach") { attach(a); logsAgent = nil }
                    .font(.system(size: 11))
                Button("Done") { logsAgent = nil }
                    .font(.system(size: 11))
            }
            ScrollView {
                Text(loadingLogs ? "Loading…" : logsText)
                    .font(.custom("Fira Code", size: 10))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 560, height: 420)
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

private struct AgentRow: View {
    let agent: AgentSession
    let scale: CGFloat
    let onAttach: () -> Void
    let onStop: () -> Void
    let onRespawn: () -> Void
    let onRemove: () -> Void
    let onLogs: () -> Void

    /// Project is always the row's headline. The home directory shows as
    /// "Home" rather than the bare folder name (e.g. "bbdaniels"). Fall back
    /// to the session name/id only when there is no working directory at all.
    private var projectTitle: String {
        let cwd = agent.cwd.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !cwd.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if cwd == home { return "Home" }
        }
        let p = agent.projectName
        if p != "—", !p.isEmpty { return p }
        return agent.name.isEmpty ? agent.id : agent.name
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: agent.bucket.systemImage)
                .font(.system(size: 12 * scale))
                .foregroundColor(agent.bucket.color)
                .frame(width: 16)
                .help(agent.bucket.label + " · " + agent.livenessLabel)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if agent.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8 * scale))
                            .foregroundColor(.secondary)
                    }
                    Text(projectTitle)
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .lineLimit(1)
                    Text(agent.bucket.label)
                        .font(.system(size: 8 * scale, weight: .semibold))
                        .foregroundColor(agent.bucket.color)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(agent.bucket.color.opacity(0.15))
                        .clipShape(Capsule())
                    if !agent.isAlive {
                        Text("exited")
                            .font(.system(size: 8 * scale))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    // Cross-reference to the Open Sessions menu: every
                    // attached row carries a visible window chip so the
                    // two views read as the same pool. Show the title
                    // when we have one (Ghostty parent), a plain
                    // "(attached)" label otherwise (Terminal/iTerm parent).
                    if agent.isOpen {
                        let label = agent.attachedWindowTitle ?? "(attached)"
                        HStack(spacing: 3) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 8 * scale))
                            Text(label)
                                .font(.system(size: 8 * scale, weight: .medium))
                        }
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                        .help(agent.attachedWindowTitle.map {
                            "Attached in Ghostty window \"\($0)\" — click ➜ to raise it"
                        } ?? "Attached via `claude attach` in a non-Ghostty terminal")
                    }
                    // Liveness blip: the daemon's state.json lags real
                    // activity by minutes for some sessions, but the
                    // transcript ticks every model turn. A tiny green
                    // dot whenever the transcript moved in the last 30s
                    // tells the user "this one is moving right now,"
                    // regardless of what the bucket says.
                    if agent.hasRecentTranscriptActivity {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5 * scale, height: 5 * scale)
                            .help("Transcript was written in the last 30s — actively moving")
                    }
                }
                if !agent.name.isEmpty, agent.name != projectTitle {
                    Text(agent.name)
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                if !agent.detail.isEmpty {
                    Text(agent.detail)
                        .font(.system(size: 10 * scale))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(agent.id)
                    if let t = agent.template, t != "claude" {
                        Text("· \(t)")
                    }
                }
                .font(.system(size: 9 * scale))
                .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onAttach) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 14 * scale))
            }
            .buttonStyle(.borderless)
            .help("Attach in a terminal tab (claude attach \(agent.id))")

            Menu {
                Button("Attach", action: onAttach)
                Button("View logs", action: onLogs)
                Divider()
                if agent.isAlive {
                    Button("Stop", action: onStop)
                } else {
                    Button("Respawn", action: onRespawn)
                }
                Button("Remove…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12 * scale))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
