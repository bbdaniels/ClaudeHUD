import Foundation
import WebKit
import os

private let logger = Logger(subsystem: "com.claudehud", category: "ClaudeWebFetcher")

/// Errors specific to the WebKit-backed claude.ai fetch path.
enum ClaudeWebError: Error, LocalizedError {
    case noContext
    case timeout
    case cloudflareChallenge   // managed challenge never cleared
    case authExpired           // session cookie invalid / login required
    case httpError(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noContext: return "Could not create claude.ai fetch context"
        case .timeout: return "claude.ai request timed out"
        case .cloudflareChallenge: return "claude.ai is behind a Cloudflare check that did not clear"
        case .authExpired: return "claude.ai session expired"
        case .httpError(let c): return "HTTP \(c)"
        case .emptyResponse: return "Empty response from claude.ai"
        }
    }
}

/// Fetches JSON from claude.ai's internal API through a hidden WKWebView.
///
/// Why this exists: as of ~2026-05, `claude.ai/api/organizations*` sits behind a
/// Cloudflare interactive challenge (response carries `cf-mitigated: challenge`).
/// A plain `URLSession` request — what `UsageService` used to do — gets a 403
/// HTML "Just a moment..." page instead of JSON, no matter the headers, so every
/// poll fails and the usage panel freezes on stale cache.
///
/// A real WebKit engine executes the challenge JS transparently (exactly like
/// Safari), Cloudflare issues a `cf_clearance` cookie, and the API can then be
/// called as a same-origin subresource — the same path the claude.ai web app
/// itself uses. `cf_clearance` persists in the default data store, so only the
/// first fetch after a challenge pays the latency; subsequent 5-minute polls are
/// fast.
@MainActor
final class ClaudeWebFetcher: NSObject {
    static let shared = ClaudeWebFetcher()

    private var webView: WKWebView?
    private var window: NSWindow?
    private var primed = false
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutWork: DispatchWorkItem?

    private let origin = "https://claude.ai"
    // Match Safari so Cloudflare sees a WebKit UA consistent with the engine.
    private let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    private override init() { super.init() }

    /// Fetch a claude.ai API path (e.g. `/api/organizations`) and return the raw
    /// JSON body. Injects `sessionKey`, lets WebKit clear Cloudflare, then runs a
    /// same-origin `fetch()` inside the page, retrying while the challenge settles.
    func json(path: String, sessionKey: String) async throws -> Data {
        // Hold an activity assertion so App Nap / timer throttling does not stall
        // the offscreen web view's challenge script.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "claude.ai usage fetch"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        try ensureWebView()
        try await injectCookie(sessionKey)
        try await prime()

        let maxAttempts = 6
        for attempt in 1...maxAttempts {
            switch try await runFetch(path: path) {
            case .ok(let data):
                if attempt > 1 {
                    logger.info("claude.ai fetch cleared after \(attempt) attempts")
                }
                return data
            case .challenge:
                if attempt == maxAttempts {
                    logger.error("Cloudflare challenge unresolved after \(maxAttempts) attempts")
                    throw ClaudeWebError.cloudflareChallenge
                }
                logger.info("Cloudflare not cleared (attempt \(attempt)/\(maxAttempts)); waiting 3s")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            case .auth:
                throw ClaudeWebError.authExpired
            case .http(let code):
                throw ClaudeWebError.httpError(code)
            }
        }
        throw ClaudeWebError.cloudflareChallenge
    }

    // MARK: - WebView lifecycle

    private func ensureWebView() throws {
        if webView != nil { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persist cf_clearance across polls
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Real, non-zero frame so the challenge script's timers / rAF run.
        let frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let wv = WKWebView(frame: frame, configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = userAgent

        let win = NSWindow(contentRect: frame,
                           styleMask: [.borderless],
                           backing: .buffered,
                           defer: false)
        win.contentView = wv
        win.isReleasedWhenClosed = false
        // Opt this helper window OUT of all window management. A default
        // NSWindow is `.managed`, so it participates in Spaces / Exposé /
        // Mission Control. Parked 20k pt offscreen, a managed window the
        // window server cannot place on any display makes macOS fan out
        // Mission Control to surface it whenever the app activates or this
        // view re-navigates (every 5-min usage poll) — the spurious
        // "zoom out". `.transient` hides it from Exposé/Mission Control
        // while still compositing it (WebKit timers/rAF keep running, so
        // the Cloudflare challenge script is not suspended).
        win.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        win.isExcludedFromWindowsMenu = true
        win.hidesOnDeactivate = false
        // Park far offscreen; never key, never user-visible. Kept on-screen
        // (not orderOut) so WebKit does not suspend the challenge script.
        win.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        win.orderBack(nil)

        self.webView = wv
        self.window = win
        logger.info("Hidden WKWebView created for claude.ai fetches")
    }

    private func injectCookie(_ sessionKey: String) async throws {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else {
            throw ClaudeWebError.noContext
        }
        guard let cookie = HTTPCookie(properties: [
            .domain: ".claude.ai",
            .path: "/",
            .name: "sessionKey",
            .value: sessionKey,
            .secure: true,
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 30),
        ]) else {
            throw ClaudeWebError.noContext
        }
        await store.setCookie(cookie)
    }

    /// Navigate the hidden web view to the claude.ai origin once so WebKit runs
    /// the Cloudflare challenge. No-op once primed.
    private func prime() async throws {
        guard let wv = webView else { throw ClaudeWebError.noContext }
        if primed { return }
        guard let url = URL(string: origin + "/") else { throw ClaudeWebError.noContext }
        var req = URLRequest(url: url)
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.loadContinuation = cont
            let work = DispatchWorkItem { [weak self] in
                guard let self, let c = self.loadContinuation else { return }
                self.loadContinuation = nil
                c.resume(throwing: ClaudeWebError.timeout)
            }
            self.loadTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
            wv.load(req)
        }
        primed = true
    }

    // MARK: - In-page fetch

    private enum FetchOutcome {
        case ok(Data)
        case challenge
        case auth
        case http(Int)
    }

    private func runFetch(path: String) async throws -> FetchOutcome {
        guard let wv = webView else { throw ClaudeWebError.noContext }
        // 15s in-JS abort so callAsyncJavaScript always returns.
        let js = """
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), 15000);
        try {
            const r = await fetch(target, {
                method: 'GET',
                credentials: 'same-origin',
                headers: { 'Accept': 'application/json' },
                signal: ctrl.signal
            });
            const body = await r.text();
            return JSON.stringify({
                status: r.status,
                ct: (r.headers.get('content-type') || ''),
                body: body
            });
        } catch (e) {
            return JSON.stringify({ status: 0, ct: '', body: String(e) });
        } finally {
            clearTimeout(t);
        }
        """
        let raw = try await wv.callAsyncJavaScript(
            js,
            arguments: ["target": origin + path],
            contentWorld: .page
        )

        guard let jsonStr = raw as? String,
              let env = try? JSONSerialization.jsonObject(
                  with: Data(jsonStr.utf8)) as? [String: Any],
              let status = env["status"] as? Int else {
            throw ClaudeWebError.emptyResponse
        }
        let ct = (env["ct"] as? String ?? "").lowercased()
        let body = env["body"] as? String ?? ""

        // Order matters: a Cloudflare interstitial can arrive as 403 *or* 200.
        if isChallenge(body: body, contentType: ct) { return .challenge }
        if status == 200, ct.contains("application/json") { return .ok(Data(body.utf8)) }
        if status == 401 || status == 403 { return .auth }
        if status == 0 { return .challenge }   // fetch aborted/blocked — retry
        return .http(status)
    }

    private func isChallenge(body: String, contentType: String) -> Bool {
        guard contentType.contains("text/html") || contentType.isEmpty else { return false }
        return body.contains("Just a moment")
            || body.contains("challenge-platform")
            || body.contains("__cf_chl")
            || body.contains("cf-mitigated")
    }
}

extension ClaudeWebFetcher: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.resumeLoad(throwing: nil) }
    }
    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumeLoad(throwing: error) }
    }
    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in self.resumeLoad(throwing: error) }
    }

    private func resumeLoad(throwing error: Error?) {
        guard let cont = loadContinuation else { return }
        loadContinuation = nil
        loadTimeoutWork?.cancel()
        loadTimeoutWork = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }
}
