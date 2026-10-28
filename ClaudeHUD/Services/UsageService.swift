import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "UsageService")

/// Fetches claude.ai subscription usage (5-hour and weekly windows) from the
/// same private endpoint backing https://claude.ai/settings/usage. Authenticates
/// via the `sessionKey` cookie stored in Keychain, refreshed from Arc when it
/// is missing or expired.
@MainActor
class UsageService: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var lastFetched: Date?
    @Published var errorMessage: String?
    @Published var hasCookie: Bool
    @Published var isLoading = false

    private var orgUUID: String?
    private var timer: Timer?

    private static let pollInterval: TimeInterval = 300 // 5 minutes

    nonisolated(unsafe) private static let cacheDir: String = {
        let dir = "\(NSHomeDirectory())/.claude/hud/usage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        hasCookie = Self.loadCookie() != nil
        if let cached = Self.loadCachedUsage() {
            usage = cached.usage
            lastFetched = cached.fetchedAt
            orgUUID = cached.orgUUID
        }
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Fetch

    func refresh() async {
        var cookie = Self.loadCookie()
        if cookie == nil { cookie = await Self.adoptArcCookie(replacing: nil) }
        guard var cookie else {
            errorMessage = "No claude.ai cookie configured, and none could be read from Arc."
            hasCookie = false
            return
        }
        hasCookie = true
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var triedArc = false
        while true {
            do {
                try await fetchAndStore(cookie: cookie)
                return
            } catch let error where Self.isAuthFailure(error) {
                // The stored cookie expired. Arc stays logged in to claude.ai,
                // so take its current sessionKey and retry once.
                if !triedArc, let fresh = await Self.adoptArcCookie(replacing: cookie) {
                    triedArc = true
                    cookie = fresh
                    orgUUID = nil  // force re-discovery with new cookie
                    continue
                }
                errorMessage = "claude.ai session expired and Arc had no newer cookie. Log in to claude.ai in Arc, or paste a cookie in the info popover."
                logger.error("Auth failed: \(error.localizedDescription)")
            } catch ClaudeWebError.cloudflareChallenge {
                errorMessage = "Blocked by a claude.ai Cloudflare check. Open claude.ai in your browser, then refresh."
                logger.error("Cloudflare challenge unresolved")
            } catch ClaudeWebError.timeout {
                errorMessage = "claude.ai timed out. Will retry on the next poll."
                logger.error("Fetch timed out")
            } catch {
                errorMessage = "Failed: \(error.localizedDescription)"
                logger.error("Fetch failed: \(error.localizedDescription)")
            }
            return
        }
    }

    private func fetchAndStore(cookie: String) async throws {
        if orgUUID == nil {
            orgUUID = try await Self.discoverOrgUUID(cookie: cookie)
        }
        guard let uuid = orgUUID else { throw UsageError.noOrganization }
        let fetched = try await Self.fetchUsage(cookie: cookie, orgUUID: uuid)
        usage = fetched
        lastFetched = Date()
        Self.saveCachedUsage(CachedUsage(usage: fetched, orgUUID: uuid, fetchedAt: Date()))
        logger.info("Usage refreshed: 5h=\(fetched.fiveHour?.utilization ?? -1)% 7d=\(fetched.sevenDay?.utilization ?? -1)%")
    }

    nonisolated private static func isAuthFailure(_ error: Error) -> Bool {
        switch error {
        case ClaudeWebError.authExpired: return true
        case ClaudeWebError.httpError(let code), UsageError.httpError(let code):
            return code == 401 || code == 403
        default: return false
        }
    }

    /// True when we have data but the last successful fetch is old enough that
    /// the displayed numbers should be treated as stale (≈6 missed polls).
    var isStale: Bool {
        guard let fetched = lastFetched else { return usage != nil }
        return Date().timeIntervalSince(fetched) > 1800
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    // MARK: - API

    // Routed through ClaudeWebFetcher (a hidden WKWebView) rather than
    // URLSession: as of ~2026-05 these endpoints sit behind a Cloudflare
    // interactive challenge that a plain URLSession request cannot pass.
    @MainActor private static func discoverOrgUUID(cookie: String) async throws -> String {
        let data = try await ClaudeWebFetcher.shared.json(
            path: "/api/organizations", sessionKey: cookie)
        struct Org: Codable { let uuid: String }
        let orgs = try JSONDecoder().decode([Org].self, from: data)
        guard let first = orgs.first else { throw UsageError.noOrganization }
        return first.uuid
    }

    @MainActor private static func fetchUsage(cookie: String, orgUUID: String) async throws -> UsageResponse {
        let data = try await ClaudeWebFetcher.shared.json(
            path: "/api/organizations/\(orgUUID)/usage", sessionKey: cookie)
        do {
            let decoded = try Self.decoder().decode(UsageResponse.self, from: data)
            // Every top-level window is optional, so a renamed/wrapped schema
            // would decode "successfully" into all-nil — a silently empty
            // panel. Treat that as drift and surface it with the payload.
            if decoded.fiveHour == nil, decoded.sevenDay == nil,
               decoded.sevenDaySonnet == nil, decoded.sevenDayOpus == nil,
               decoded.sevenDayOauthApps == nil, decoded.sevenDayCowork == nil {
                let head = String(data: data.prefix(700), encoding: .utf8) ?? "<non-utf8 \(data.count)B>"
                logger.error("Usage decoded to all-nil windows (schema drift?) payload: \(head, privacy: .public)")
                throw UsageError.schemaDrift
            }
            return decoded
        } catch let err as DecodingError {
            // The endpoint is a private API and its shape drifts. Without the
            // payload in the log, a drift surfaces only as the opaque
            // "The data couldn't be read because it is missing." — log the
            // precise decode context and the head of the body (public: this
            // is the user's own usage data on their own machine).
            let head = String(data: data.prefix(700), encoding: .utf8) ?? "<non-utf8 \(data.count)B>"
            logger.error("Usage decode failed: \(String(describing: err), privacy: .public) payload: \(head, privacy: .public)")
            throw err
        }
    }

    // MARK: - Date decoding
    // claude.ai returns ISO-8601 with microsecond precision e.g. "2026-04-05T02:00:00.352727+00:00"
    // which ISO8601DateFormatter cannot parse directly. Strip to millisecond precision.

    nonisolated private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseAPIDate(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date: \(raw)")
        }
        return decoder
    }

    nonisolated private static func parseAPIDate(_ str: String) -> Date? {
        // Trim fractional precision below milliseconds.
        // "2026-04-05T02:00:00.352727+00:00" -> "2026-04-05T02:00:00.352+00:00"
        var trimmed = str
        if let dot = trimmed.firstIndex(of: ".") {
            // Find the end of the fractional block (first non-digit after the dot).
            let afterDot = trimmed.index(after: dot)
            if let offsetStart = trimmed[afterDot...].firstIndex(where: { !$0.isNumber }) {
                let fractionalDigits = trimmed.distance(from: afterDot, to: offsetStart)
                if fractionalDigits > 3 {
                    let keepEnd = trimmed.index(afterDot, offsetBy: 3)
                    trimmed.replaceSubrange(keepEnd..<offsetStart, with: "")
                }
            }
        }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: trimmed) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    // MARK: - Cookie (SecretsVault)

    static func saveCookie(_ cookie: String) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        SecretsVault.shared.write(\.claudeAiCookie, trimmed.isEmpty ? nil : trimmed)
        logger.info("claude.ai cookie saved to vault")
    }

    static func loadCookie() -> String? {
        SecretsVault.shared.read(\.claudeAiCookie)
    }

    static func deleteCookie() {
        SecretsVault.shared.write(\.claudeAiCookie, nil)
        logger.info("claude.ai cookie deleted from vault")
    }

    /// Save Arc's claude.ai `sessionKey` when it differs from `current`, and
    /// return it. Nil when Arc is not reachable, has no cookie, or has the same
    /// one. Skipped while the vault is locked, because a write then would
    /// persist a blob holding only this cookie and drop the other secrets.
    private static func adoptArcCookie(replacing current: String?) async -> String? {
        guard SecretsVault.shared.isUnlocked else { return nil }
        guard let fresh = await sessionKeyFromArc(), fresh != current else { return nil }
        saveCookie(fresh)
        logger.info("claude.ai cookie imported from Arc")
        return fresh
    }

    /// Reads claude.ai's `sessionKey` from the running Arc over its DevTools
    /// port (`Storage.getCookies` on the browser target). Arc is the browser
    /// Ben stays logged in to claude.ai with, so its cookie is the current one.
    nonisolated static func sessionKeyFromArc() async -> String? {
        struct Version: Decodable { let webSocketDebuggerUrl: String }
        struct Cookie: Decodable { let name: String; let value: String; let domain: String; let expires: Double }
        struct Reply: Decodable {
            struct Result: Decodable { let cookies: [Cookie] }
            let id: Int?
            let result: Result?
        }
        do {
            // `localhost`, not 127.0.0.1: Arc binds the port to [::1] only.
            let versionURL = URL(string: "http://localhost:9222/json/version")!
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: versionURL, timeoutInterval: 3))
            let version = try JSONDecoder().decode(Version.self, from: data)
            guard let wsURL = URL(string: version.webSocketDebuggerUrl) else { return nil }

            let socket = URLSession.shared.webSocketTask(with: wsURL)
            socket.maximumMessageSize = 64 << 20  // the full cookie jar exceeds the 1 MB default
            socket.resume()
            defer { socket.cancel(with: .normalClosure, reason: nil) }
            try await socket.send(.string(#"{"id":1,"method":"Storage.getCookies"}"#))
            while true {
                let message = try await socket.receive()
                let body: Data
                switch message {
                case .string(let text): body = Data(text.utf8)
                case .data(let raw): body = raw
                @unknown default: continue
                }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: body), reply.id == 1 else { continue }
                return reply.result?.cookies
                    .filter { $0.name == "sessionKey" && $0.domain.hasSuffix("claude.ai") }
                    .max { $0.expires < $1.expires }?
                    .value
            }
        } catch {
            logger.info("Arc cookie read failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Allow external UI to notify the service that cookie state changed.
    func cookieDidChange() {
        hasCookie = Self.loadCookie() != nil
        orgUUID = nil  // force re-discovery with new cookie
        Task { await refresh() }
    }

    // MARK: - Cache

    nonisolated private static func cachePath() -> String { "\(cacheDir)/usage.json" }

    nonisolated private static func loadCachedUsage() -> CachedUsage? {
        guard let data = FileManager.default.contents(atPath: cachePath()) else { return nil }
        return try? decoder().decode(CachedUsage.self, from: data)
    }

    nonisolated private static func saveCachedUsage(_ cached: CachedUsage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cached) else { return }
        FileManager.default.createFile(atPath: cachePath(), contents: data)
    }
}

enum UsageError: Error, LocalizedError {
    case badURL
    case httpError(Int)
    case noOrganization
    case schemaDrift

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL"
        case .httpError(let code): return "HTTP \(code)"
        case .noOrganization: return "No organization found"
        case .schemaDrift: return "claude.ai changed the usage response format"
        }
    }
}
