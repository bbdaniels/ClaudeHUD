import Foundation

/// A single usage window returned by claude.ai/api/organizations/{uuid}/usage
struct UsageWindow: Codable, Equatable {
    let utilization: Double
    /// nil between windows: right after a window resets and before the next
    /// claude.ai activity opens one, the API returns `"resets_at": null`.
    /// A required Date here made the whole usage decode fail at exactly that
    /// boundary ("The data couldn't be read because it is missing.").
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerate explicit nulls AND missing keys on both fields — the
        // endpoint is a private API and its shape drifts.
        utilization = try c.decodeIfPresent(Double.self, forKey: .utilization) ?? 0
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
    }

    /// Construct directly from a `limits[]` entry (percent + reset date).
    init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// One entry of the usage payload's `limits` array. As of ~2026-07 claude.ai
/// reports per-model weekly usage HERE, not in the flat `seven_day_<model>`
/// keys (which now come back null): a `weekly_scoped` limit carries
/// `scope.model.display_name` (e.g. "Fable"). `kind` ∈ {session, weekly_all,
/// weekly_scoped}. Lenient — only `kind` is required.
struct UsageLimit: Codable, Equatable {
    let kind: String
    let percent: Double?
    let severity: String?
    let resetsAt: Date?
    let isActive: Bool?
    let scope: Scope?

    struct Scope: Codable, Equatable {
        let model: Model?
        struct Model: Codable, Equatable {
            let id: String?
            let displayName: String?
            enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" }
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    /// Model display name for a scoped limit (e.g. "Fable"), else nil.
    var modelName: String? { scope?.model?.displayName }

    /// Row label: "5-hour window" / "Weekly (all)" / "Weekly (<Model>)".
    var label: String {
        switch kind {
        case "session": return "5-hour window"
        case "weekly_all": return "Weekly (all)"
        case "weekly_scoped": return "Weekly (\(modelName ?? "scoped"))"
        default: return modelName.map { "Weekly (\($0))" } ?? kind
        }
    }
}

struct ExtraUsage: Codable, Equatable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

/// Response from GET /api/organizations/{uuid}/usage
struct UsageResponse: Codable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayFable: UsageWindow?
    let sevenDayCowork: UsageWindow?
    let extraUsage: ExtraUsage?
    /// Per-limit array. As of ~2026-07 this is where claude.ai reports
    /// per-model weekly usage (a `weekly_scoped` entry with
    /// `scope.model.display_name`, e.g. "Fable"); the flat `seven_day_<model>`
    /// keys above now come back null. UsageBadge renders per-model rows from
    /// here and falls back to the flat fields.
    let limits: [UsageLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        // Legacy flat per-model keys — verified null in the live payload
        // (2026-07-20); kept as a fallback and to keep the drift guard
        // meaningful. Real per-model data moved to `limits` (see UsageLimit).
        case sevenDayFable = "seven_day_fable"
        case sevenDayCowork = "seven_day_cowork"
        case extraUsage = "extra_usage"
        case limits
    }
}

/// Cached snapshot persisted to disk
struct CachedUsage: Codable {
    let usage: UsageResponse
    let orgUUID: String
    let fetchedAt: Date
}
