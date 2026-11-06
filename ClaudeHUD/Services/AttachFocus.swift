/// Which terminal a click on a session raises (Ben, 2026-11-06).
///
/// Only one the click itself confirms: the attach found by a fresh process
/// scan (`AgentsService.scanAttaches`, run at the click), in the Ghostty
/// process that owns it. Before this, a click trusted the session's attach
/// as last scanned and, when that window was gone, raised any Ghostty window
/// whose title held the session's folder name. On 2026-11-06 a session in
/// bare ~/Projects had just had its window closed; the first click raised a
/// MacBook shell titled "Projects" whose ssh had ended, and only the second
/// click opened the session. With no confirmed attach the click opens a new
/// one instead.
///
/// Pure, so the rule is unit tested; `AgentsService.open` scans and acts.
enum AttachFocus {
    enum Target: Equatable {
        /// Focus the terminal on `tty` in Ghostty process `pid`, or failing
        /// that raise that process's window.
        case terminal(pid: Int32, tty: String?)
        /// Not attached anywhere this click can see: open a new attach.
        case openNew
    }

    /// `key` is the session's attach key (`AgentsService.attachKey`), nil
    /// when it has none; `fresh` maps each key to the Ghostty pid and tty of
    /// its attach, as scanned at the click.
    static func target(key: String?, fresh: [String: (ghosttyPid: Int32?, tty: String?)]) -> Target {
        guard let key, let found = fresh[key], let pid = found.ghosttyPid else { return .openNew }
        return .terminal(pid: pid, tty: found.tty)
    }
}
