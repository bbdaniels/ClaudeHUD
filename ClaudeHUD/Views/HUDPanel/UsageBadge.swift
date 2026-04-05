import SwiftUI

/// Compact pill badge in the header showing 5-hour usage %.
/// Click opens a popover with the full breakdown.
struct UsageBadge: View {
    @EnvironmentObject var usageService: UsageService
    @State private var showPopover = false
    @Environment(\.fontScale) private var scale

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.smallFont(scale))
                if let label = displayLabel {
                    Text(label)
                        .font(.smallFont(scale))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(0.15))
            )
            .foregroundColor(tint)
        }
        .buttonStyle(.borderless)
        .help(tooltipText)
        .popover(isPresented: $showPopover) {
            UsagePopover()
                .environmentObject(usageService)
        }
    }

    private var iconName: String { "gauge.with.dots.needle.50percent" }

    private var displayLabel: String? {
        guard let pct = usageService.usage?.fiveHour?.utilization else { return nil }
        return "\(Int(pct.rounded()))%"
    }

    private var tint: Color {
        guard usageService.hasCookie else { return .secondary }
        guard let pct = usageService.usage?.fiveHour?.utilization else { return .secondary }
        switch pct {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    private var tooltipText: String {
        if !usageService.hasCookie {
            return "Set claude.ai cookie in info popover to enable usage tracking"
        }
        guard let u = usageService.usage else { return "Fetching usage…" }
        var parts: [String] = []
        if let fh = u.fiveHour {
            parts.append("5-hour: \(Int(fh.utilization.rounded()))% (resets \(relativeReset(fh.resetsAt)))")
        }
        if let wd = u.sevenDay {
            parts.append("Weekly: \(Int(wd.utilization.rounded()))% (resets \(relativeReset(wd.resetsAt)))")
        }
        return parts.joined(separator: "\n")
    }

    private func relativeReset(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Full breakdown shown when the badge is clicked.
struct UsagePopover: View {
    @EnvironmentObject var usageService: UsageService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage")
                    .font(.custom("Fira Sans", size: 13).weight(.semibold))
                Spacer()
                Button(action: { Task { await usageService.refresh() } }) {
                    if usageService.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(usageService.isLoading)
                .help("Refresh now")
            }

            if !usageService.hasCookie {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No cookie configured.")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary)
                    Text("Open the info popover (i) and paste your claude.ai sessionKey cookie to enable usage tracking.")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let err = usageService.errorMessage, usageService.usage == nil {
                Text(err)
                    .font(.custom("Fira Sans", size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let u = usageService.usage {
                VStack(alignment: .leading, spacing: 10) {
                    if let fh = u.fiveHour {
                        UsageRow(label: "5-hour window", window: fh)
                    }
                    if let wd = u.sevenDay {
                        UsageRow(label: "Weekly (all)", window: wd)
                    }
                    if let opus = u.sevenDayOpus {
                        UsageRow(label: "Weekly (Opus)", window: opus)
                    }
                    if let sonnet = u.sevenDaySonnet {
                        UsageRow(label: "Weekly (Sonnet)", window: sonnet)
                    }
                    if let extra = u.extraUsage, extra.isEnabled {
                        Divider()
                        HStack {
                            Text("Overage")
                                .font(.custom("Fira Sans", size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            if let pct = extra.utilization {
                                Text("\(Int(pct.rounded()))%")
                                    .font(.custom("Fira Code", size: 11))
                            } else {
                                Text("enabled")
                                    .font(.custom("Fira Sans", size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    if let fetched = usageService.lastFetched {
                        Text("Updated \(relativeString(fetched))")
                            .font(.custom("Fira Sans", size: 10))
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
            } else {
                Text("Loading…")
                    .font(.custom("Fira Sans", size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func relativeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct UsageRow: View {
    let label: String
    let window: UsageWindow

    private var tint: Color {
        switch window.utilization {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    private var resetString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "resets " + formatter.localizedString(for: window.resetsAt, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.custom("Fira Sans", size: 11))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.custom("Fira Code", size: 11).weight(.medium))
                    .foregroundColor(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
                        .frame(width: max(0, min(1, window.utilization / 100.0)) * geo.size.width, height: 4)
                }
            }
            .frame(height: 4)
            Text(resetString)
                .font(.custom("Fira Sans", size: 9))
                .foregroundColor(.secondary)
        }
    }
}
