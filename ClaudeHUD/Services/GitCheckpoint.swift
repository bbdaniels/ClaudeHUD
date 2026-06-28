import Foundation

// MARK: - Phase 1.7: git checkpoint / diff / undo safety primitive

/// A pre-turn snapshot of the project's working tree, recorded before a turn
/// that may edit real files so the operator can later SEE (`Show diff`) or
/// REVERSE (`Undo turn`) exactly what the turn changed — from a phone, one tap.
///
/// The snapshot is a `git stash create` commit: a dangling commit whose tree is
/// the current working tree, captured WITHOUT touching the index or working tree
/// (so taking a checkpoint is side-effect-free). When the tree is clean,
/// `stash create` is empty and the snapshot falls back to HEAD. We also record
/// HEAD and the set of untracked files at checkpoint time, so undo can remove
/// files the turn newly created and diff can list them.
///
/// `Codable` so the checkpoint survives an app restart (the terminal card's
/// Diff/Undo buttons persist in Slack and must keep working after a relaunch).
struct GitCheckpoint: Codable {
    let cwd: String
    let head: String              // HEAD commit, or "" in an empty repo
    let snapshot: String          // pre-turn tree commit; "" if uncapturable
    let dirtyAtStart: Bool        // tree had uncommitted edits BEFORE the turn
    let untrackedAtStart: [String]
    let createdAt: Date

    /// Diff / undo are only meaningful when we captured a real snapshot.
    var isCapturable: Bool { !snapshot.isEmpty }
}

/// Stateless git operations behind `GitCheckpoint`. Every call shells out to
/// `/usr/bin/git` as an ARGV ARRAY (never a shell string, so there is no
/// metacharacter-injection surface), off the MainActor.
enum GitCheckpointService {
    private static let gitPath = "/usr/bin/git"

    /// Run `git <args>` in `cwd`, returning exit status + trimmed stdout/stderr.
    @discardableResult
    static func run(_ args: [String], cwd: String) async -> (status: Int32, out: String, err: String) {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gitPath)
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let outPipe = Pipe(), errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            do {
                try p.run()
            } catch {
                return (-1, "", error.localizedDescription)
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = (String(data: outData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let err = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (p.terminationStatus, out, err)
        }.value
    }

    /// True when `cwd` is inside a git work tree (so the Diff/Undo affordances
    /// and the checkpoint apply at all).
    static func isRepo(_ cwd: String) async -> Bool {
        let r = await run(["rev-parse", "--is-inside-work-tree"], cwd: cwd)
        return r.status == 0 && r.out == "true"
    }

    static func untrackedFiles(cwd: String) async -> [String] {
        let r = await run(["ls-files", "--others", "--exclude-standard"], cwd: cwd)
        guard r.status == 0, !r.out.isEmpty else { return [] }
        return r.out.split(separator: "\n").map(String.init)
    }

    /// Take a side-effect-free checkpoint of the current working tree. Returns
    /// nil when `cwd` is not a git repo (the caller then hides the buttons).
    static func make(cwd: String) async -> GitCheckpoint? {
        guard await isRepo(cwd) else { return nil }
        let headR = await run(["rev-parse", "HEAD"], cwd: cwd)
        let head = headR.status == 0 ? headR.out : ""
        // `stash create` snapshots the working tree+index into a dangling commit
        // without modifying either; empty output ⇒ clean tree ⇒ snapshot = HEAD.
        let stash = await run(["stash", "create"], cwd: cwd)
        let snapshot = (stash.status == 0 && !stash.out.isEmpty) ? stash.out : head
        let status = await run(["status", "--porcelain"], cwd: cwd)
        let dirty = !status.out.isEmpty
        let untracked = await untrackedFiles(cwd: cwd)
        return GitCheckpoint(cwd: cwd, head: head, snapshot: snapshot,
                             dirtyAtStart: dirty, untrackedAtStart: untracked,
                             createdAt: Date())
    }

    /// `git diff` of what the turn changed since the checkpoint, plus a list of
    /// any newly-created untracked files (which `git diff` does not show).
    static func diff(_ cp: GitCheckpoint) async -> String {
        guard cp.isCapturable else { return "" }
        let d = await run(["diff", cp.snapshot], cwd: cp.cwd)
        var out = d.out
        let nowUntracked = Set(await untrackedFiles(cwd: cp.cwd))
        let added = nowUntracked.subtracting(cp.untrackedAtStart).sorted()
        if !added.isEmpty {
            out += (out.isEmpty ? "" : "\n\n")
                + "# new files (untracked):\n"
                + added.map { "+ \($0)" }.joined(separator: "\n")
        }
        return out
    }

    /// Restore the working tree to the pre-turn checkpoint. Tracked files are
    /// reverted to the snapshot tree; untracked files the turn newly created are
    /// removed. The CURRENT state is first snapshotted to
    /// `refs/claudehud/undo-safety` so the undo is itself recoverable.
    static func undo(_ cp: GitCheckpoint) async -> (ok: Bool, detail: String) {
        guard cp.isCapturable else { return (false, "no checkpoint to restore") }

        // Safety net: capture the present state before we overwrite it.
        let safety = await run(["stash", "create"], cwd: cp.cwd)
        if safety.status == 0, !safety.out.isEmpty {
            _ = await run(["update-ref", "refs/claudehud/undo-safety", safety.out], cwd: cp.cwd)
        }

        // Revert tracked files to the checkpoint tree.
        let restore = await run(["checkout", cp.snapshot, "--", "."], cwd: cp.cwd)

        // Remove untracked files that appeared during the turn (present now,
        // absent at checkpoint) — never the operator's pre-existing untracked.
        let nowUntracked = Set(await untrackedFiles(cwd: cp.cwd))
        let added = nowUntracked.subtracting(cp.untrackedAtStart)
        var removed = 0
        for rel in added {
            let path = (cp.cwd as NSString).appendingPathComponent(rel)
            if (try? FileManager.default.removeItem(atPath: path)) != nil { removed += 1 }
        }

        let ok = restore.status == 0
        let detail: String
        if ok {
            var s = "Restored tracked files to the pre-turn checkpoint"
            s += removed > 0 ? "; removed \(removed) new file\(removed == 1 ? "" : "s")." : "."
            detail = s
        } else {
            detail = "git checkout failed: \(restore.err.isEmpty ? "unknown" : restore.err)"
        }
        return (ok, detail)
    }
}
