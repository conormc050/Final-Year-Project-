//
//  Theme.swift
//  TUS-RISE
//
//  Design system: cyan accent, glassmorphism, shared components.
//

import SwiftUI

enum Theme {
    static let accent       = Color(red: 0.13, green: 0.83, blue: 0.93)  // #22d3ee
    static let accentStrong = Color(red: 0.02, green: 0.71, blue: 0.83)  // #06b6d4
    static let accentDeep   = Color(red: 0.05, green: 0.65, blue: 0.91)  // #0ea5e9
    static let good = Color(red: 0.20, green: 0.83, blue: 0.60)          // #34d399
    static let warn = Color(red: 0.98, green: 0.75, blue: 0.14)          // #fbbf24
    static let bad  = Color(red: 0.98, green: 0.44, blue: 0.52)          // #fb7185

    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.40, green: 0.91, blue: 0.98), accent, accentDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// App background: soft cyan radial glows over the system background.
    static var backgroundGradient: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            RadialGradient(colors: [accentDeep.opacity(0.20), .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 460)
            RadialGradient(colors: [accent.opacity(0.10), .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 420)
        }
    }
}

// MARK: - Research disclaimer

/// Ethics/validity footnote shown wherever results are presented. Design
/// principle 4: never present these metrics as medical or coaching truth —
/// this is a research prototype, and the angles are only valid side-on.
struct DisclaimerNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text("Research prototype — not medical or coaching advice. Angles assume a side-on (sagittal) camera view and are normalised to your own calibration, not clinical measurements.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Glass card

struct GlassCard<Content: View>: View {
    var label: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.3)
                    .foregroundStyle(.tertiary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let value: String
    let unit: String?
    let name: String

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 24, weight: .heavy))
                if let unit {
                    Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Score pill

struct ScorePill: View {
    let score: Int?

    private var color: Color {
        guard let s = score else { return Theme.warn }
        return s >= 85 ? Theme.good : s >= 65 ? Theme.warn : Theme.bad
    }

    var body: some View {
        Text(score.map(String.init) ?? "–")
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Score ring

struct ScoreRing: View {
    let score: Int?
    var size: CGFloat = 168
    @State private var progress: CGFloat = 0
    @State private var shown: Int = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: size * 0.078)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.accentGradient,
                        style: StrokeStyle(lineWidth: size * 0.078, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(shown)")
                    .font(.system(size: size * 0.26, weight: .heavy))
                    .contentTransition(.numericText())
                Text("Form score")
                    .font(.system(size: size * 0.072))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            let target = score ?? 0
            withAnimation(.easeOut(duration: 1.1)) {
                progress = CGFloat(target) / 100
            }
            // count-up
            Task { @MainActor in
                for step in stride(from: 0, through: target, by: max(1, target / 30)) {
                    shown = step
                    try? await Task.sleep(for: .milliseconds(28))
                }
                shown = target
            }
        }
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: LiftSession

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                    .frame(width: 46, height: 46)
                Image(systemName: session.exercise == "deadlift" ? "figure.strengthtraining.functional" : "figure.strengthtraining.traditional")
                    .foregroundStyle(Theme.accentStrong)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.exercise.capitalized) · \(session.repCount) reps")
                    .font(.system(size: 15, weight: .bold))
                Text("\(session.date.formatted(.relative(presentation: .named))) · \(session.flaggedReps > 0 ? "\(session.flaggedReps) flagged" : "clean")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ScorePill(score: session.score)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}
