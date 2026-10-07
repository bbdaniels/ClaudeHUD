import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "ClaudeProcessMonitor")

/// Keeps a current `ClaudeProcessReport` for the menu-bar menu: background
/// jobs, orphans and the total memory of Claude Code processes.
///
/// Scans every 15 minutes and whenever the menu opens (a scan is one `ps`,
/// one `lsof` over the workers and a few small JSON reads, about 0.1 s).
/// It NEVER closes anything by itself. Close is `close(_:)`, reached only from
/// a confirmed menu click: on 2026-10-05 a process that looked orphaned was a
/// live 8-day monitoring job.
@MainActor
final class ClaudeProcessMonitor: ObservableObject {
    @Published private(set) var report = ClaudeProcessReport()
    /// Called on the main actor after every scan (the status-item badge).
    var onUpdate: ((ClaudeProcessReport) -> Void)?

    static let interval: TimeInterval = 15 * 60
    private var timer: DispatchSourceTimer?
    private var scanning = false

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: Self.interval, leeway: .seconds(30))
        t.setEventHandler { [weak self] in Task { @MainActor in await self?.refresh() } }
        t.resume()
        timer = t
    }

    /// Synchronous scan for the menu, which is built synchronously. Cheap
    /// enough (about 0.1 s) to run on the click.
    @discardableResult
    func refreshNow() -> ClaudeProcessReport {
        let r = ClaudeProcessSnapshot.capture()
        publish(r)
        return r
    }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let r = await Task.detached(priority: .utility) { ClaudeProcessSnapshot.capture() }.value
        publish(r)
    }

    private func publish(_ r: ClaudeProcessReport) {
        report = r
        onUpdate?(r)
    }

    /// Close one orphan, after the user confirmed it.
    ///
    /// A daemon session (it has a short id) is first asked to stop through
    /// the CLI's own verb, `claude stop <id>`, so the daemon records it as
    /// stopped rather than crashed and it stays resumable. Whatever is still
    /// running 5 s later, and every process of an orphan with no session, gets
    /// SIGTERM, then SIGKILL after another 5 s. Each signal is sent only to a
    /// pid whose command line still matches the one recorded at scan time, so
    /// a recycled pid is never hit.
    func close(_ w: ClassifiedWorker) async {
        guard w.cls.isOrphan else { return }
        logger.notice("Closing orphan \(w.project, privacy: .public) root=\(w.rootPid) short=\(w.short ?? "-", privacy: .public)")
        let list = w.killList
        if let short = w.short {
            let r = await AgentsService.stopAndWait(short)
            if r.code != 0 { logger.notice("claude stop \(short, privacy: .public) exited \(r.code)") }
            if await Self.waitGone(list, seconds: 5) { await refresh(); return }
        }
        Self.signal(list, SIGTERM)
        if !(await Self.waitGone(list, seconds: 5)) {
            Self.signal(list, SIGKILL)
            _ = await Self.waitGone(list, seconds: 2)
        }
        await refresh()
    }

    /// Rows of `list` still running the same command.
    nonisolated static func survivors(_ list: [ProcRow]) -> [ProcRow] {
        let now = ClaudeProcessSnapshot.processTable()
        return list.filter { now.rows[$0.pid]?.command == $0.command }
    }

    nonisolated static func signal(_ list: [ProcRow], _ sig: Int32) {
        for p in survivors(list) { kill(pid_t(p.pid), sig) }
    }

    nonisolated static func waitGone(_ list: [ProcRow], seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if survivors(list).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return survivors(list).isEmpty
    }
}
