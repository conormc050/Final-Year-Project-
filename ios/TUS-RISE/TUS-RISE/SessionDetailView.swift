//
//  SessionDetailView.swift
//  TUS-RISE
//
//  Per-session analysis. "Simple" = score + plain-language insights
//  for newer lifters; "Detailed" = full charts, rep table, baselines.
//

import SwiftUI
import Charts

struct SessionDetailView: View {
    let session: LiftSession
    @EnvironmentObject private var store: SessionStore
    @AppStorage("tusrise.viewMode") private var defaultMode = "simple"
    @State private var mode: Mode = .simple
    @State private var didSave = false
    @Environment(\.dismiss) private var dismiss

    private var isSaved: Bool { didSave || store.isSaved(session.id) }

    enum Mode: String, CaseIterable { case simple = "Simple", detailed = "Detailed" }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)

                        if mode == .simple {
                            SimpleModeView(session: session)
                        } else {
                            DetailedModeView(session: session)
                        }

                        DisclaimerNote()
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("\(session.exercise.capitalized) session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.good)
                    } else {
                        Button {
                            store.save(session)
                            withAnimation(.snappy) { didSave = true }
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .tint(Theme.accentStrong)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Text(session.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear {
                // Raw-angle sessions (video analysis before the rules engine
                // lands) have no reps — Simple mode would just say "not enough
                // data", so jump straight to the charts.
                if session.reps.isEmpty && !session.frames.isEmpty {
                    mode = .detailed
                } else {
                    mode = defaultMode == "detailed" ? .detailed : .simple
                }
            }
        }
    }
}

// MARK: - Simple mode

private struct SimpleModeView: View {
    let session: LiftSession

    var body: some View {
        VStack(spacing: 14) {
            GlassCard {
                VStack(spacing: 8) {
                    ScoreRing(score: session.score)
                    Text(blurb)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 12) {
                StatTile(value: "\(session.repCount)", unit: nil, name: "Reps")
                StatTile(value: session.bestDepth.map { "\(Int($0))" } ?? "–", unit: "°", name: "Deepest rep")
                StatTile(value: "\(session.flaggedReps)", unit: nil, name: "Flagged reps")
            }

            GlassCard(label: "Your reps") {
                VStack(alignment: .leading, spacing: 12) {
                    FlowRepDots(reps: session.reps)
                    Text("Green = clean rep · Red = form flag raised")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            GlassCard(label: "What we noticed") {
                VStack(spacing: 0) {
                    let insights = Insight.build(for: session)
                    ForEach(insights.indices, id: \.self) { i in
                        InsightRow(insight: insights[i])
                        if i < insights.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    private var blurb: String {
        guard let s = session.score else { return "Not enough data to score this session." }
        switch s {
        case 90...: return "Excellent lifting — form held up across the whole set."
        case 80...: return "Strong session with minor things to tidy up."
        case 65...: return "Solid work — a few reps need attention."
        default:    return "Form broke down in this set. Worth reviewing before adding weight."
        }
    }
}

private struct FlowRepDots: View {
    let reps: [RepStat]
    private let cols = [GridItem(.adaptive(minimum: 44), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
            ForEach(reps) { r in
                Text(r.isFailed ? "✗" : "\(r.rep)")
                    .font(.system(size: 14, weight: .heavy))
                    .frame(width: 44, height: 44)
                    .background((r.flags > 0 || r.isFailed ? Theme.bad : Theme.good).opacity(0.15), in: Circle())
                    .overlay(Circle().strokeBorder(
                        (r.flags > 0 || r.isFailed ? Theme.bad : Theme.good).opacity(0.45), lineWidth: 1.5))
                    .foregroundStyle(r.flags > 0 || r.isFailed ? Theme.bad : Theme.good)
            }
        }
    }
}

struct Insight {
    enum Kind { case good, warn, bad, info }
    let kind: Kind
    let icon: String
    let title: String
    let body: String

    var color: Color {
        switch kind {
        case .good: return Theme.good
        case .warn: return Theme.warn
        case .bad:  return Theme.bad
        case .info: return Theme.accent
        }
    }

    static func build(for s: LiftSession) -> [Insight] {
        var out: [Insight] = []
        if !s.calibrated {
            out.append(.init(kind: .warn, icon: "exclamationmark.triangle",
                title: "No calibration baseline",
                body: "The video didn't start with you standing still, so spine flags couldn't be checked. Stand upright for ~2 seconds before your first rep."))
        }
        let failed = s.reps.filter(\.isFailed).map { "\($0.rep)" }
        if !failed.isEmpty {
            out.append(.init(kind: .bad, icon: "xmark.octagon",
                title: "Failed rep detected (rep \(failed.joined(separator: ", ")))",
                body: "The ascent stalled and reversed before lockout — this rep wasn't completed under control. Failed reps are excluded from your form assessment; consider ending the set one rep sooner."))
        }
        if s.flaggedReps == 0 && s.calibrated {
            out.append(.init(kind: .good, icon: "checkmark.seal",
                title: "Spine position held",
                body: "Your lower back stayed within your neutral range on every rep. That's exactly what we want to see under load."))
        } else if s.flaggedReps > 0 {
            let which = s.reps.filter { $0.flags > 0 }.map { "\($0.rep)" }.joined(separator: ", ")
            out.append(.init(kind: .bad, icon: "flag",
                title: "Lower-back rounding on rep \(which)",
                body: "Your lumbar spine rounded past your normal range while standing up out of the hole. This usually shows up as fatigue sets in — consider stopping a rep earlier or dropping the load slightly."))
        }
        let depths = s.reps.compactMap(\.depth)
        if depths.count >= 2 {
            let spread = depths.max()! - depths.min()!
            if spread > 12 {
                out.append(.init(kind: .warn, icon: "ruler",
                    title: "Depth varied between reps",
                    body: "Your deepest and shallowest reps differed by \(Int(spread))°. Aim to hit the same depth every rep — a consistent bottom position makes every rep count the same."))
            } else {
                out.append(.init(kind: .good, icon: "target",
                    title: "Consistent depth",
                    body: "Every rep reached roughly the same bottom position. Great motor control."))
            }
        }
        let durs = s.reps.compactMap(\.duration)
        if durs.count >= 3, let last = durs.last, let first = durs.first, last > first * 1.5 {
            out.append(.init(kind: .info, icon: "timer",
                title: "Reps slowed down late in the set",
                body: "Later reps took noticeably longer — a normal fatigue signal, and a good cue for when to rack it."))
        }
        if out.isEmpty {
            out.append(.init(kind: .info, icon: "lightbulb",
                title: "Session recorded",
                body: "Not enough rep data for deeper insights this time."))
        }
        return out
    }
}

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.icon)
                .frame(width: 34, height: 34)
                .background(insight.color.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .foregroundStyle(insight.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.system(size: 14, weight: .bold))
                Text(insight.body)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Detailed mode

private struct DetailedModeView: View {
    let session: LiftSession

    var body: some View {
        VStack(spacing: 14) {
            GlassCard(label: "Joint angles across the lift") {
                AngleTimelineChart(session: session)
                    .frame(height: 230)
            }

            GlassCard(label: "Peak lean per rep") {
                Chart {
                    ForEach(session.reps) { r in
                        if let t = r.trunk {
                            BarMark(x: .value("Rep", "R\(r.rep)"), y: .value("Trunk", t))
                                .foregroundStyle(Theme.warn.opacity(0.85))
                                .position(by: .value("Series", "Trunk"))
                        }
                        if let l = r.lumbar {
                            BarMark(x: .value("Rep", "R\(r.rep)"), y: .value("Lumbar", l))
                                .foregroundStyle(r.flags > 0 ? Theme.bad : Theme.bad.opacity(0.75))
                                .position(by: .value("Series", "Lumbar"))
                        }
                    }
                    if let base = session.lumbarBaseline {
                        RuleMark(y: .value("Baseline", base))
                            .foregroundStyle(Theme.bad.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        RuleMark(y: .value("Threshold", base + session.threshold))
                            .foregroundStyle(Color.red.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    }
                }
                .frame(height: 210)
            }

            GlassCard(label: "Rep breakdown") {
                Grid(horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        ForEach(["Rep", "Time", "Depth", "Trunk", "Lumbar", "Flags"], id: \.self) { h in
                            Text(h.uppercased())
                                .font(.system(size: 10.5, weight: .bold)).kerning(0.8)
                                .foregroundStyle(.tertiary)
                                .gridColumnAlignment(.leading)
                        }
                    }
                    Divider()
                    ForEach(session.reps) { r in
                        GridRow {
                            Text("\(r.rep)")
                            Text(r.duration.map { "\($0)s" } ?? "–")
                            Text(r.depth.map { "\(Int($0))°" } ?? "–")
                            Text(r.trunk.map { "\(Int($0))°" } ?? "–")
                            Text(r.lumbar.map { "\(Int($0))°" } ?? "–")
                            Text(r.isFailed ? "✗ failed" : (r.flags > 0 ? "\(r.flags) ⚑" : "✓"))
                                .foregroundStyle(r.flags > 0 || r.isFailed ? Theme.bad : Theme.good)
                                .fontWeight(.heavy)
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                }
            }

            GlassCard(label: "Calibration & thresholds") {
                VStack(spacing: 0) {
                    KVRow(key: "Calibrated", value: session.calibrated ? "Yes" : "No ⚠️")
                    Divider().opacity(0.4)
                    KVRow(key: "Lumbar baseline",
                          value: session.lumbarBaseline.map { String(format: "%.1f°", $0) } ?? "–")
                    Divider().opacity(0.4)
                    KVRow(key: "Trunk baseline",
                          value: session.trunkBaseline.map { String(format: "%.1f°", $0) } ?? "–")
                    Divider().opacity(0.4)
                    KVRow(key: "Flag threshold", value: "baseline + \(Int(session.threshold))°")
                    Divider().opacity(0.4)
                    KVRow(key: "Frames analysed", value: "\(session.frames.count)")
                    Divider().opacity(0.4)
                    KVRow(key: "Processing rate",
                          value: "every \(session.everyN) frame(s) @ \(Int(session.fps)) fps")
                }
            }
        }
    }
}

/// Multi-line angle timeline with flagged spans + baseline rules.
private struct AngleTimelineChart: View {
    let session: LiftSession

    // Downsample so the chart stays smooth on long sets
    private var samples: [FrameSample] {
        let f = session.frames
        guard f.count > 600 else { return f }
        let stride = f.count / 600
        return f.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
    }

    var body: some View {
        Chart {
            ForEach(samples) { f in
                if let v = f.knee_angle {
                    LineMark(x: .value("Frame", f.frame), y: .value("°", v), series: .value("S", "Knee"))
                        .foregroundStyle(Theme.good)
                }
                if let v = f.hip_angle {
                    LineMark(x: .value("Frame", f.frame), y: .value("°", v), series: .value("S", "Hip"))
                        .foregroundStyle(Theme.warn)
                }
                if let v = f.trunk_lean {
                    LineMark(x: .value("Frame", f.frame), y: .value("°", v), series: .value("S", "Trunk"))
                        .foregroundStyle(Color.orange)
                }
                if let v = f.lumbar_lean {
                    LineMark(x: .value("Frame", f.frame), y: .value("°", v), series: .value("S", "Lumbar"))
                        .foregroundStyle(Theme.bad)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 3]))
                }
            }
            .lineStyle(StrokeStyle(lineWidth: 1.6))

            // flagged spans
            ForEach(flagSpans, id: \.0) { span in
                RectangleMark(xStart: .value("s", span.0), xEnd: .value("e", span.1))
                    .foregroundStyle(Theme.bad.opacity(0.12))
            }

            if let base = session.lumbarBaseline {
                RuleMark(y: .value("Baseline", base))
                    .foregroundStyle(Theme.bad.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [5, 4]))
                RuleMark(y: .value("Threshold", base + session.threshold))
                    .foregroundStyle(Color.red.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [5, 4]))
            }
        }
        .chartLegend(.hidden)
        .chartXAxisLabel("Frame")
    }

    private var flagSpans: [(Int, Int)] {
        let flagged = session.frames.filter(\.lumbar_flag).map(\.frame)
        guard !flagged.isEmpty else { return [] }
        var spans: [(Int, Int)] = []
        var start = flagged[0], prev = flagged[0]
        for f in flagged.dropFirst() {
            if f - prev > session.everyN * 3 { spans.append((start, prev)); start = f }
            prev = f
        }
        spans.append((start, prev))
        return spans
    }
}
