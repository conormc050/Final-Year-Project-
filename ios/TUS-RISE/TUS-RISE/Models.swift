//
//  Models.swift
//  TUS-RISE
//
//  Data model matching the JSON exported by VidCalc.py
//  (session_<video>.json, schema_version 1), plus the session
//  store with bundled mock data and file import.
//

import Foundation
import Combine   // for ObservableObject / @Published

// MARK: - Codable payload (mirrors VidCalc export exactly)

nonisolated struct SessionPayload: Codable {
    var schema_version: Int?
    var video: String?
    var exercise: String?
    var date: String?
    var fps: Double?
    var process_every_n: Int?
    var rep_count: Int?
    var lumbar_baseline: Double?
    var trunk_baseline: Double?
    var lumbar_flex_threshold: Double?
    var calibrated: Bool?
    var reps: [RepStat]?
    var frames: [FrameSample]?
}

nonisolated struct RepStat: Codable, Identifiable {
    var rep: Int
    var duration: Double?
    var depth: Double?
    var trunk: Double?
    var lumbar: Double?
    var flags: Int
    /// True when the ascent collapsed mid-rep (bar dumped / rep not
    /// completed under control). Optional so pre-existing saved sessions
    /// still decode; nil means "not evaluated", treat as not failed.
    var failed: Bool?
    var id: Int { rep }

    var isFailed: Bool { failed == true }
}

nonisolated struct FrameSample: Codable, Identifiable {
    var frame: Int
    var knee_angle: Double?
    var hip_angle: Double?
    var trunk_lean: Double?
    var lumbar_lean: Double?
    var phase: String
    var rep_count: Int
    var lumbar_flag: Bool
    var id: Int { frame }
}

// MARK: - App-facing session

struct LiftSession: Identifiable {
    let id: String
    let video: String
    let exercise: String
    let date: Date
    let fps: Double
    let everyN: Int
    let repCount: Int
    let lumbarBaseline: Double?
    let trunkBaseline: Double?
    let threshold: Double
    let calibrated: Bool
    let reps: [RepStat]
    let frames: [FrameSample]

    var flaggedReps: Int { reps.filter { $0.flags > 0 }.count }

    var bestDepth: Double? {
        reps.compactMap(\.depth).min()
    }

    /// Form score heuristic (0–100): penalises lumbar flags,
    /// shallow depth, and inconsistent depth. Mirrors the web prototype.
    /// Failed reps are excluded — an aborted ascent isn't graded on form.
    var score: Int? {
        let counted = reps.filter { !$0.isFailed }
        guard !counted.isEmpty else { return nil }
        var s = 100.0
        let totalFlags = counted.reduce(0) { $0 + $1.flags }
        s -= min(45, Double(totalFlags) * 2.2)
        let depths = counted.compactMap(\.depth)
        if !depths.isEmpty {
            let avg = depths.reduce(0, +) / Double(depths.count)
            if avg > 100 { s -= min(20, (avg - 100) * 0.8) }
            let spread = depths.max()! - depths.min()!
            s -= min(15, max(0, spread - 12) * 0.9)
        }
        if !calibrated { s -= 10 }
        return max(0, Int(s.rounded()))
    }

    init(payload: SessionPayload, id: String = UUID().uuidString) {
        self.id = id
        self.video = payload.video ?? "unknown.mp4"
        self.exercise = payload.exercise ?? "squat"
        self.date = payload.date.flatMap { ISO8601DateFormatter.flexible.date(from: $0) } ?? Date()
        self.fps = payload.fps ?? 30
        self.everyN = payload.process_every_n ?? 1
        self.reps = payload.reps ?? []
        self.repCount = payload.rep_count ?? self.reps.count
        self.lumbarBaseline = payload.lumbar_baseline
        self.trunkBaseline = payload.trunk_baseline
        self.threshold = payload.lumbar_flex_threshold ?? 12
        self.calibrated = (payload.calibrated ?? true) && payload.lumbar_baseline != nil
        self.frames = payload.frames ?? []
    }

    /// Rebuild the Codable payload for persistence (mirrors the analyzer's export).
    func payload() -> SessionPayload {
        SessionPayload(schema_version: 1,
                       video: video,
                       exercise: exercise,
                       date: ISO8601DateFormatter.flexible.string(from: date),
                       fps: fps,
                       process_every_n: everyN,
                       rep_count: repCount,
                       lumbar_baseline: lumbarBaseline,
                       trunk_baseline: trunkBaseline,
                       lumbar_flex_threshold: threshold,
                       calibrated: calibrated,
                       reps: reps,
                       frames: frames)
    }
}

extension ISO8601DateFormatter {
    /// Accepts both with and without fractional seconds.
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Store

@MainActor
final class SessionStore: ObservableObject {
    /// Saved reviews only. A session isn't kept until the user taps Save on
    /// its review — analysed-but-unsaved sessions stay ephemeral.
    @Published private(set) var sessions: [LiftSession] = []

    /// Documents/Sessions — one JSON file per saved review.
    private let dir: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// On-disk record: the versioned payload plus the app-side session id.
    private struct Stored: Codable { let id: String; let payload: SessionPayload }

    init() { load() }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        sessions = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let s = try? decoder.decode(Stored.self, from: data) else { return nil }
                return LiftSession(payload: s.payload, id: s.id)
            }
            .sorted { $0.date > $1.date }
    }

    var sorted: [LiftSession] { sessions.sorted { $0.date > $1.date } }
    var latest: LiftSession? { sorted.first }

    func session(id: String) -> LiftSession? { sessions.first { $0.id == id } }

    /// Whether a review has already been saved to disk.
    func isSaved(_ id: String) -> Bool { sessions.contains { $0.id == id } }

    /// Persist a just-analysed review to disk and surface it in History.
    func save(_ session: LiftSession) {
        guard !isSaved(session.id) else { return }
        if let data = try? JSONEncoder().encode(Stored(id: session.id, payload: session.payload())) {
            try? data.write(to: dir.appendingPathComponent("\(session.id).json"))
        }
        sessions.insert(session, at: 0)
    }

    /// Clear cache: delete every saved review from disk and memory.
    func clearAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" { try? FileManager.default.removeItem(at: f) }
        sessions = []
    }

    // Aggregates ---------------------------------------------------

    struct WeekStats { let sessions: Int; let reps: Int; let avgScore: Int? }

    var weekStats: WeekStats {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let wk = sessions.filter { $0.date >= cutoff }
        let scores = wk.compactMap(\.score)
        return WeekStats(
            sessions: wk.count,
            reps: wk.reduce(0) { $0 + $1.repCount },
            avgScore: scores.isEmpty ? nil : scores.reduce(0, +) / scores.count
        )
    }

    struct TrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let score: Int?
        let avgDepth: Double?
        let flagRate: Double
    }

    var trendPoints: [TrendPoint] {
        sorted.reversed().map { s in
            let depths = s.reps.compactMap(\.depth)
            return TrendPoint(
                date: s.date,
                score: s.score,
                avgDepth: depths.isEmpty ? nil : depths.reduce(0, +) / Double(depths.count),
                flagRate: s.repCount > 0 ? Double(s.flaggedReps) / Double(s.repCount) * 100 : 0
            )
        }
    }
}
