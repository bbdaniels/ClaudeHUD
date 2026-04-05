import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "UsageService")

/// Fetches claude.ai subscription usage (5-hour and weekly windows) from the
/// same private endpoint backing https://claude.ai/settings/usage. Authenticates
/// via the `sessionKey` cookie stored in Keychain.
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
        guard let cookie = Self.loadCookie() else {
            errorMessage = "No claude.ai cookie configured."
            hasCookie = false
            return
        }
        hasCookie = true
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if orgUUID == nil {
                orgUUID = try await Self.discoverOrgUUID(cookie: cookie)
            }
            guard let uuid = orgUUID else {
                errorMessage = "Could not discover organization."
                return
            }
            let fetched = try await Self.fetchUsage(cookie: cookie, orgUUID: uuid)
            usage = fetched
            lastFetched = Date()
            Self.saveCachedUsage(CachedUsage(usage: fetched, orgUUID: uuid, fetchedAt: Date()))
            logger.info("Usage refreshed: 5h=\(fetched.fiveHour?.utilization ?? -1)% 7d=\(fetched.sevenDay?.utilization ?? -1)%")
        } catch UsageError.httpError(let code) where code == 401 || code == 403 {
            errorMessage = "Cookie expired. Update it in the info popover."
            logger.error("Auth failed (HTTP \(code))")
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
            logger.error("Fetch failed: \(error.localizedDescription)")
        }
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

    nonisolated private static func discoverOrgUUID(cookie: String) async throws -> String {
        guard let url = URL(string: "https://claude.ai/api/organizations") else {
            throw UsageError.badURL
        }
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(cookie)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UsageError.httpError(http.statusCode)
        }
        struct Org: Codable { let uuid: String }
        let orgs = try JSONDecoder().decode([Org].self, from: data)
        guard let first = orgs.first else { throw UsageError.noOrganization }
        return first.uuid
    }

    nonisolated private static func fetchUsage(cookie: String, orgUUID: String) async throws -> UsageResponse {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgUUID)/usage") else {
            throw UsageError.badURL
        }
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(cookie)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UsageError.httpError(http.statusCode)
        }
        return try Self.decoder().decode(UsageResponse.self, from: data)
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

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL"
        case .httpError(let code): return "HTTP \(code)"
        case .noOrganization: return "No organization found"
        }
    }
}
