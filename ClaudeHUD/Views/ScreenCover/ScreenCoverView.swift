//  Adapted from Lockpaw, Copyright (c) 2025 Erik Nielsen, MIT License,
//  https://github.com/sorkila/lockpaw

import SwiftUI

struct ScreenCoverView: View {
    @ObservedObject var service: ScreenCoverService
    @ObservedObject var agents: AgentsService
    let isPrimary: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // One monotonic phase, not a 0→1 loop: a wrapping loop snaps the paw
    // every cycle. 1 unit ≈ 12s, so this lasts about two weeks.
    @State private var phase: CGFloat = 0
    @State private var glow: Double = Self.glowRest
    @State private var glowGeneration = 0

    private static let glowRest = 0.06
    private static let phaseTarget: CGFloat = 100_000

    private var breathe: Double {
        guard !reduceMotion else { return 0.5 }
        return (sin(Double(phase) * 2 * .pi) + 1) / 2
    }

    private var liveAgents: [AgentSession] {
        agents.agents.filter(\.isAlive)
    }

    private var needsInputCount: Int {
        liveAgents.filter { $0.bucket == .needsInput }.count
    }

    private var activitySignature: String {
        liveAgents.map { "\($0.id):\($0.bucket.label)" }.sorted().joined(separator: "|")
    }

    private var agentLine: String {
        let count = liveAgents.count
        let base = count == 1 ? "1 agent running" : "\(count) agents running"
        guard needsInputCount > 0 else { return base }
        return "\(base) · \(needsInputCount) needs input"
    }

    var body: some View {
        GeometryReader { geo in
            let pawSize = min(geo.size.width * 0.16, geo.size.height * 0.26)
            let unit = max(pawSize * 0.12, 8)

            ZStack {
                Color.black.ignoresSafeArea()

                RadialGradient(
                    stops: [
                        .init(color: Color.accentColor.opacity(0.26 * glow), location: 0),
                        .init(color: Color.accentColor.opacity(0.12 * glow), location: 0.45),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.8
                )
                .ignoresSafeArea()
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

                VStack(spacing: unit) {
                    Text("🐾")
                        .font(.system(size: pawSize))
                        .shadow(color: Color.accentColor.opacity(0.18 + breathe * 0.10),
                                radius: 34 + breathe * 8, y: 10)
                        .shadow(color: .black.opacity(0.15), radius: 45, y: 30)
                        .offset(y: breathe * 4)
                        .opacity(0.55 + breathe * 0.25)

                    if isPrimary {
                        primaryContent(unit: unit)
                    } else {
                        Text(service.lockMessage)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.32))
                    }
                }
                .frame(maxWidth: geo.size.width * 0.8)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.44)
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityAddTraits(.isModal)
        .onAppear { startBreathing() }
        .onChange(of: activitySignature) { _, _ in pulse() }
    }

    @ViewBuilder
    private func primaryContent(unit: CGFloat) -> some View {
        VStack(spacing: unit * 0.55) {
            Text(service.lockMessage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)

            Text(agentLine)
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .foregroundStyle(needsInputCount > 0
                                 ? Color.yellow.opacity(0.75)
                                 : Color.white.opacity(0.40))
                .contentTransition(.numericText())

            statusLine
                .frame(height: 22)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if service.isAuthenticating {
            Text("Authenticating…")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
        } else if let error = service.lastError {
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(Color.red.opacity(0.8))
        } else {
            Text(service.requiresAuthentication
                 ? "Press any key to unlock with Touch ID"
                 : "Press any key to unlock")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.22))
        }
    }

    private func startBreathing() {
        if service.lastError == nil, needsInputCount > 0 {
            glow = Self.glowRest * 2
        }
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 12 * Double(Self.phaseTarget)).repeatForever(autoreverses: false)) {
            phase = Self.phaseTarget
        }
    }

    /// One slow breath on an activity tick — reads from across a room without
    /// flashing the display.
    private func pulse() {
        glowGeneration += 1
        let generation = glowGeneration
        guard !reduceMotion else {
            glow = Self.glowRest
            return
        }
        withAnimation(.easeInOut(duration: 1.1)) { glow = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard generation == glowGeneration else { return }
            withAnimation(.easeInOut(duration: 1.5)) { glow = Self.glowRest }
        }
    }
}
