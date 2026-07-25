//
//  RulesEngine.swift
//  TUS-RISE
//
//  Faithful port of VidCalc.py's rep state machine, calibration, and
//  rules engine (step 4 of the iOS port). Pure logic — Foundation only,
//  no Vision/UIKit — so it can move into the portable analysis package
//  and be unit-tested against JSON fixtures from the Python pipeline.
//
//  SpinePose (step 5) now supplies lumbar/trunk lean, so the lumbar+trunk
//  baseline locks together from the first standing frames (matching VidCalc)
//  and the lumbar-flexion flag fires; `calibrated` is true once it locks.
//  A trunk-only fallback still locks trunk alone if SpinePose fails to
//  produce lumbar on a clip, so trunk numbers degrade gracefully.
//
//  Smoothing: One Euro on positions (Smoothing.swift, PointSmoother) plus a
//  median spike-rejection stage on the knee signal here (kneeSpikeWindow) —
//  needed because Vision 3D angle jitter otherwise splits reps and fakes
//  collapses. See RulesConfig.failedRepRise for the full failed-rep design.
//

import Foundation

/// Mirrors the CONFIG block in VidCalc.py — keep names and values in sync.
nonisolated struct RulesConfig {
    var squatEntryAngle: Double = 120    // knee below this → rep started
    var squatExitAngle: Double = 125     // knee above this (after entry) → rep complete
    var minRepFrames: Int = 8            // minimum processed frames for a real rep
    var calibrationFrames: Int = 40      // standing frames needed to lock the baseline
    var lumbarFlexThreshold: Double = 12 // degrees over baseline that trigger a flag

    /// Knee angle the lifter must exceed (stand back up) after a rep before
    /// the next one can start. Deviation from VidCalc.py — added because a
    /// grindy ascent that slows through the narrow 120–125° band wobbles
    /// across both thresholds and double-counts one physical rep. Requiring
    /// a return toward standing re-arms the counter once per real rep and
    /// can't be reached by a mid-ascent sticking-point wobble.
    ///
    /// 135° chosen from Squat1 data: its touch-and-go reps only recover to
    /// 141/151/155° between reps (so 135 re-arms every real rep), while a
    /// synthetic grind wobble tops out ~128° (so it can't re-arm and stops
    /// the double-count). Provisional — retune against Conor's failing clip.
    var repRearmAngle: Double = 135

    /// Failed-rep detection (iOS addition, not in VidCalc). Tracked online,
    /// per rep: keep the running minimum knee (the deepest point *so far*)
    /// and the highest angle reached *since* that minimum (the ascent
    /// attempt). A failure fires when the attempt rose at least
    /// `failedRepRise` above that minimum and then dropped at least
    /// `failedRepCollapse` back from its peak, before lockout.
    ///
    /// Why online + reset-on-new-minimum is the robust design (hard-won,
    /// 2026-07-21, validated frame-by-frame on Conor's real Squat3 clip):
    /// a real descent has a HITCH on the way down (e.g. 119 → dip 51 →
    /// bounce 72 → true bottom 40). Because the peak resets every time a new
    /// minimum is set, a descent hitch only ever shows a small rise (~20°)
    /// and never triggers. The genuine dumped rep (bottom 45 → stand-up
    /// attempt 102 → collapse to 15/2 as the bar is dropped) shows a 57°
    /// rise then an 87° collapse — unmistakable. Catching it online also
    /// beats a post-pass "global minimum" approach, which gets fooled by the
    /// garbage-low readings that follow a real collapse. Thresholds picked
    /// with margin: on the real clip the worst good-rep collapse-from-peak
    /// was 25°, so 30° clears it.
    ///
    /// Three additions (2026-07-23) made this robust on real Vision 3D data,
    /// where the online rule alone false-flagged good reps. Validated on the
    /// device Squat3 trace AND the MediaPipe fixture — both yield exactly
    /// {rep 6}: (1) `kneeSpikeWindow` median rejection so 1-frame Vision blips
    /// don't fabricate collapses or split reps; (2) `validRepDepth` gate so
    /// shallow between-rep noise dips aren't counted as reps; (3) a dumped rep
    /// that never recovers to standing (the lifter stays down / the clip ends
    /// low) is closed and flagged at end-of-pass — the completion path never
    /// sees it, so it was previously detected then silently discarded.
    var failedRepRise: Double = 25
    var failedRepCollapse: Double = 30

    /// Spike-rejection window (odd) applied to the knee signal before rep
    /// detection. Vision 3D emits single-frame angle spikes that both split
    /// real reps (a 127° blip mid-descent trips the exit threshold) and
    /// fabricate collapses; a 3-wide median removes them while preserving a
    /// sustained bar dump. Clean sources (MediaPipe world landmarks) need no
    /// rejection and set this to 1 — their genuine dumps are themselves sharp
    /// 1–2 frame crashes that filtering would erase.
    var kneeSpikeWindow: Int = 3

    /// A rep only counts if its knee reached at least this deep. Vision noise
    /// dips briefly below the 120° entry between reps (to ~90–115°) with no
    /// real squat; requiring genuine depth discards those phantom reps. Real
    /// squats bottom well under 62°, so 100° separates them cleanly.
    var validRepDepth: Double = 100
}

nonisolated enum RulesEngine {

    struct Result {
        var frames: [FrameSample]        // phase / rep_count / lumbar_flag filled in
        var reps: [RepStat]
        var repCount: Int
        var lumbarBaseline: Double?
        var trunkBaseline: Double?
        var calibrated: Bool             // true only when the spine baseline locked
    }

    /// Run the state machine over per-frame angles (already in VidCalc's
    /// processed-frame order) and tag phases, count reps, and apply rules.
    static func process(frames rawFrames: [FrameSample],
                        fps: Double,
                        processEveryN: Int,
                        config: RulesConfig = RulesConfig()) -> Result {
        var kneeHistory: [Double] = []   // rolling window; trend needs last 4
        var inRep = false
        var framesInRep = 0
        var repCount = 0
        var phase = "STANDING"
        // Re-arm guard: the counter must see the lifter stand up (knee past
        // repRearmAngle) before a new rep can begin. Starts armed so the
        // first rep counts.
        var armed = true

        // Failed-rep tracking (online): deepest knee so far in the current
        // rep, the highest angle reached since that deepest point (the
        // ascent attempt), and whether this rep has collapsed.
        var repMinKnee = Double.infinity
        var repPeakSinceMin = -Double.infinity
        var repFailed = false
        var failedReps: Set<Int> = []

        var calibLumbar: [Double] = []
        var calibTrunk: [Double] = []
        var calibrationDone = false
        var lumbarBaseline: Double?
        var trunkBaseline: Double?

        // Reject single-frame pose spikes on the knee signal before detection
        // (see RulesConfig.kneeSpikeWindow). Filter only the non-nil samples,
        // in order, then map back so nil frames stay nil.
        let kneeIdx = rawFrames.indices.filter { rawFrames[$0].knee_angle != nil }
        let kneeVals = medianFiltered(kneeIdx.map { rawFrames[$0].knee_angle! },
                                      window: config.kneeSpikeWindow)
        var filteredKnee = [Double?](repeating: nil, count: rawFrames.count)
        for (k, i) in kneeIdx.enumerated() { filteredKnee[i] = kneeVals[k] }

        // Depth gate: a rep only counts once its knee has gone genuinely deep;
        // shallow between-rep noise dips are discarded. `repStartIdx` marks
        // where the current rep's frames begin, so a phantom can be erased.
        var reachedDepth = false
        var repStartIdx = 0

        var frames: [FrameSample] = []
        frames.reserveCapacity(rawFrames.count)

        for (i, rawFrame) in rawFrames.enumerated() {
            var f = rawFrame
            // ---- Rep detection — state machine on knee angle ----
            if let knee = filteredKnee[i] {
                f.knee_angle = knee   // store the de-spiked value for charts/depth
                kneeHistory.append(knee)
                if kneeHistory.count > 7 { kneeHistory.removeFirst() }

                if armed && !inRep && knee < config.squatEntryAngle {
                    inRep = true
                    armed = false          // must fully stand up before next rep
                    framesInRep = 0
                    repMinKnee = knee
                    repPeakSinceMin = knee
                    repFailed = false
                    repStartIdx = frames.count            // first frame of this rep
                    reachedDepth = knee < config.validRepDepth
                }

                if inRep {
                    framesInRep += 1
                    if knee < config.validRepDepth { reachedDepth = true }

                    // Failed-ascent detection. Check the collapse BEFORE
                    // updating the running minimum, so a fast dump that
                    // overshoots below the attempt bottom still registers.
                    // Reset the peak whenever a new, deeper minimum is set —
                    // this is what makes a descent hitch (which keeps making
                    // new minimums) never look like an ascent collapse.
                    if repPeakSinceMin - repMinKnee >= config.failedRepRise,
                       repPeakSinceMin - knee >= config.failedRepCollapse,
                       knee < config.squatExitAngle {
                        repFailed = true
                    } else if knee < repMinKnee {
                        repMinKnee = knee
                        repPeakSinceMin = knee
                    } else {
                        repPeakSinceMin = max(repPeakSinceMin, knee)
                    }

                    if kneeHistory.count >= 4 {
                        let trend = kneeHistory[kneeHistory.count - 1] - kneeHistory[kneeHistory.count - 4]
                        if trend < -3 {
                            phase = "DESCENDING"
                        } else if trend > 3 {
                            phase = "ASCENDING"
                        } else {
                            phase = "BOTTOM"
                        }
                    }

                    if knee > config.squatExitAngle && framesInRep >= config.minRepFrames {
                        inRep = false
                        phase = "STANDING"
                        if reachedDepth {
                            repCount += 1
                            if repFailed { failedReps.insert(repCount) }
                        } else {
                            // Shallow phantom (a noise dip, never a real squat):
                            // erase its frames so it isn't counted or bucketed
                            // into the next rep by repStats.
                            for j in repStartIdx..<frames.count { frames[j].phase = "STANDING" }
                        }
                    }
                } else {
                    phase = "STANDING"
                    // Re-arm once the lifter has clearly stood back up.
                    if knee >= config.repRearmAngle { armed = true }
                }
            }

            // ---- Calibration — lock baseline from first N standing frames ----
            if !calibrationDone && !inRep {
                if let lumbar = f.lumbar_lean { calibLumbar.append(lumbar) }
                if let trunk = f.trunk_lean { calibTrunk.append(trunk) }
                if calibLumbar.count >= config.calibrationFrames,
                   calibTrunk.count >= config.calibrationFrames {
                    lumbarBaseline = calibLumbar.reduce(0, +) / Double(calibLumbar.count)
                    trunkBaseline = calibTrunk.reduce(0, +) / Double(calibTrunk.count)
                    calibrationDone = true
                }
                // Temporary trunk-only lock (see header) so trunk numbers work
                // before SpinePose provides lumbar data.
                if trunkBaseline == nil, calibTrunk.count >= config.calibrationFrames {
                    trunkBaseline = calibTrunk.reduce(0, +) / Double(calibTrunk.count)
                }
            }

            // ---- Rules engine ----
            var lumbarFlag = false
            if phase == "ASCENDING",
               calibrationDone,
               let lumbar = f.lumbar_lean,
               let baseline = lumbarBaseline,
               lumbar > baseline + config.lumbarFlexThreshold {
                lumbarFlag = true
            }

            f.phase = phase
            f.rep_count = repCount
            f.lumbar_flag = lumbarFlag
            frames.append(f)
        }

        // Dumped final rep: a collapse was detected but the lifter never
        // stood back up (bar dropped; the clip ends deep), so the completion
        // path never counts it. Close and flag it here. Its frames already
        // carry rep_count = repCount, so repStats buckets them into this rep
        // once totalReps includes it.
        if inRep && repFailed && reachedDepth {
            repCount += 1
            failedReps.insert(repCount)
        }

        let reps = repStats(frames: frames, totalReps: repCount,
                            fps: fps, processEveryN: processEveryN,
                            failedReps: failedReps)

        return Result(frames: frames,
                      reps: reps,
                      repCount: repCount,
                      lumbarBaseline: lumbarBaseline,
                      trunkBaseline: trunkBaseline,
                      calibrated: calibrationDone)
    }

    /// Port of compute_rep_stats(): group tagged frames by rep and summarise.
    static func repStats(frames: [FrameSample],
                         totalReps: Int,
                         fps: Double,
                         processEveryN: Int,
                         failedReps: Set<Int> = []) -> [RepStat] {
        var buckets: [Int: [FrameSample]] = [:]
        for f in frames where f.phase != "STANDING" {
            let rep = f.rep_count + 1        // rep in progress = completed + 1
            guard rep <= totalReps else { continue }   // skip incomplete last rep
            buckets[rep, default: []].append(f)
        }

        func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

        return buckets.keys.sorted().map { rep in
            let fr = buckets[rep]!
            let knees = fr.compactMap(\.knee_angle)
            let trunks = fr.compactMap(\.trunk_lean)
            let lumbars = fr.compactMap(\.lumbar_lean)
            return RepStat(rep: rep,
                           duration: round1(Double(fr.count * processEveryN) / fps),
                           depth: knees.min().map(round1),
                           trunk: trunks.max().map(round1),
                           lumbar: lumbars.max().map(round1),
                           flags: fr.filter(\.lumbar_flag).count,
                           failed: failedReps.contains(rep) ? true : nil)
        }
    }
}
