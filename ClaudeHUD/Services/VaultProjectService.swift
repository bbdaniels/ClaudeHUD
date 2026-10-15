import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.claudehud", category: "VaultProjectService")

/// Lists projects in the Obsidian vault and surfaces their canonical
/// per-project metadata (the `Tasks.md` frontmatter: status, updated, cwds,
/// manuscript, parent) for the Projects tab, plus the cwd → project join the
/// live-session badges use. The `## Active` task parser lives in
/// `ActiveTasks.swift`.
///
/// Architecture: see Projects/obsidian/ClaudeHUD/Technical Notes.md
/// §Vault/Projects tab redistribution. The HUD is a window over the
/// archive; this service does no synthesis — every value rendered in
/// the Projects tab is a verbatim slice of a vault file.
@MainActor
final class VaultProjectService: ObservableObject {

    // MARK: - Public types

    /// The project model lives in `VaultProjectTree.swift` (Foundation-only, so
    /// the unit tests compile it directly) together with the scan and the
    /// parent → children tree.
    typealias Project = VaultProject

    // MARK: - Published state

    @Published private(set) var projects: [Project] = []

    // MARK: - Configuration

    private(set) var vaultPath: URL?

    /// Bumped at the start of every `refresh()`; a scan publishes only if it
    /// is still the newest, so a slow scan that finishes after
    /// a later one can never overwrite fresher results.
    private var scanGeneration = 0

    // MARK: - Lifecycle

    func start(vaultPath: URL?) {
        self.vaultPath = vaultPath
        refresh()
    }

    /// Re-scan the vault. Call from view `onAppear` or explicitly after
    /// the vault changes. NOT cheap: it reads every project's `Tasks.md` in
    /// full. While the vault lived in iCloud (until 2026-10-15) a cold scan
    /// blocked 0.5–2 s per file (a 39 s main-thread hang when this ran
    /// synchronously). The scan therefore runs detached; only the
    /// publish touches the main actor. Fire-and-forget; `await` it when
    /// the caller needs the fresh list.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        scanGeneration &+= 1
        let generation = scanGeneration
        guard let vault = vaultPath else {
            projects = []
            return Task {}
        }
        return Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) {
                VaultProject.scan(vaultPath: vault)
            }.value
            guard let self, generation == self.scanGeneration else { return }
            self.projects = out
            logger.info("vault projects refreshed: \(out.count) total, \(out.filter { $0.isActive }.count) active")
        }
    }

    /// Insert (or replace) one project parsed from `folder`, re-sorted into
    /// place, without waiting for a full scan — used right after "New
    /// Project" so the row appears at once. Parses via the same
    /// `VaultProject.parse` as the scan; one small folder, so a main-actor read
    /// of a just-written (never evicted) file is fine. Returns the project.
    @discardableResult
    func insertProject(folder: URL) -> Project? {
        guard let p = VaultProject.parse(folder: folder) else { return nil }
        var out = projects.filter { $0.name != p.name }
        out.append(p)
        projects = VaultProject.sorted(out)
        return p
    }

    // MARK: - Canonical cwd → vault-folder resolution (the session → project join key)

    /// Cache of repo working-directory → resolved vault folder NAME. The value
    /// is itself optional: `.some(nil)` records a cwd that resolves to NO
    /// project (so it is not re-scanned); an absent key means "not yet
    /// resolved." Keyed by absolute cwd. Primed off the main actor by
    /// `primeResolution`; read synchronously via `folderName(forCwd:)`.
    private var cwdFolderCache: [String: String?] = [:]

    /// Resolve every cwd in `cwds` to its vault folder using the ONE canonical
    /// rule, `ProjectResolver.resolveFolder` (the longest matching `cwds:`
    /// claim wins; with none, the cwd's normalized `git remote get-url origin`
    /// against `repo:`), caching the results. The disk scan and the git calls
    /// (themselves cached per cwd by `RepoLocator`) run off the main actor; only the
    /// small cache merge touches the actor. Call this before reading
    /// `folderName(forCwd:)` in a render path so lookups are warm. Cheap on
    /// repeat: only cache misses are scanned.
    func primeResolution(forCwds cwds: Set<String>) async {
        guard let vaultRoot = vaultPath?.path else { return }
        let misses = cwds.filter { cwdFolderCache[$0] == nil }
        guard !misses.isEmpty else { return }
        let resolved: [String: String?] = await Task.detached(priority: .userInitiated) {
            var out: [String: String?] = [:]
            for cwd in misses {
                out[cwd] = ProjectResolver.resolveFolder(cwd: cwd, vaultPath: vaultRoot)
            }
            return out
        }.value
        for (k, v) in resolved { cwdFolderCache[k] = v }
    }

    /// Cached resolved vault folder NAME for a repo cwd (nil = unclaimed, or
    /// not yet primed). Pure cache read — call `primeResolution(forCwds:)`
    /// first. Matches `Project.name` (the folder basename) for filtering.
    func folderName(forCwd cwd: String) -> String? {
        cwdFolderCache[cwd] ?? nil
    }

    // MARK: - Live sessions per project

    /// folder name → the live INTERACTIVE sessions among `agents`. THE
    /// session-to-project join for anything that acts on a project's open
    /// windows: the Projects badges, the badge's click-to-focus, and the
    /// launcher's window-or-tab decision all read it, so they cannot disagree
    /// about which sessions belong to a project. Unsorted: ordering is only
    /// needed on click, and the Projects list calls this on every body pass.
    func liveSessionsByFolder(in agents: [AgentSession]) -> [String: [AgentSession]] {
        var map: [String: [AgentSession]] = [:]
        for a in agents {
            guard a.isAlive, a.isOpen, !a.cwd.isEmpty,
                  let folder = folderName(forCwd: a.cwd) else { continue }
            // Only the three badged buckets: an alive+open session in an
            // unrecognized daemon state (`.other`) must not be click-cyclable
            // when the badge never advertised it.
            switch a.bucket {
            case .working, .needsInput, .idle: break
            default: continue
            }
            map[folder, default: []].append(a)
        }
        return map
    }

    /// The live sessions of `folders`, merged, most recently active first: one
    /// folder for a project's own sessions (a child row's badge, and every
    /// launch), a parent's folder plus its children's for the parent row's
    /// badge.
    ///
    /// `updatedAt` alone is not the recency: the daemon flushes `state.json`
    /// event-driven and can lag minutes behind an actively working session,
    /// while the transcript ticks on every turn — so the later of the two is
    /// the honest ordering.
    func liveSessions(forFolders folders: [String], in agents: [AgentSession]) -> [AgentSession] {
        func recency(_ a: AgentSession) -> Date {
            max(a.updatedAt ?? .distantPast, a.transcriptMtime ?? .distantPast)
        }
        let byFolder = liveSessionsByFolder(in: agents)
        return folders.flatMap { byFolder[$0] ?? [] }.sorted { recency($0) > recency($1) }
    }
}
