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
    let sevenDayCowork: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case extraUsage = "extra_usage"
    }
}

/// Cached snapshot persisted to disk
struct CachedUsage: Codable {
    let usage: UsageResponse
    let orgUUID: String
    let fetchedAt: Date
}
