//
//  Smoothing.swift
//  TUS-RISE
//
//  One Euro filter + PointSmoother, ported from VidCalc.py (which uses the
//  `OneEuroFilter` pip package + its own PointSmoother). Positions are
//  filtered BEFORE angles are computed — never the reverse — because raw
//  keypoint jitter (±2–3°) is what splits one rep into two at the
//  120°/125° knee thresholds. This is the fix for over-counting reps.
//
//  Params mirror VidCalc CONFIG: mincutoff 1.0 Hz, beta 0.3, reset gap
//  0.5 s (a point gone longer than that starts with fresh filter state
//  instead of dragging stale history into its comeback).
//

import Foundation

/// Median filter for spike rejection on a scalar time series. `window` is an
/// odd width; edges shrink to the available samples. It removes transient
/// excursions shorter than half the window (single-frame pose-estimator
/// spikes) while preserving sustained moves (a real bar dump). Applied to the
/// knee signal before rep detection: Vision 3D needs window 3 (its 1-frame
/// angle blips otherwise split reps and fabricate collapses); clean sources
/// like MediaPipe use window 1, since their genuine dumps are themselves sharp
/// 1–2 frame crashes that filtering would erase.
nonisolated func medianFiltered(_ xs: [Double], window: Int) -> [Double] {
    guard window > 1, xs.count > 2 else { return xs }
    let half = window / 2
    return xs.indices.map { i in
        let lo = max(0, i - half)
        let hi = min(xs.count - 1, i + half)
        let w = xs[lo...hi].sorted()
        return w[w.count / 2]
    }
}

/// Canonical One Euro low-pass stage.
private nonisolated struct LowPassFilter {
    private var hatXPrev: Double?
    private(set) var rawPrev: Double?

    mutating func filter(_ x: Double, alpha: Double) -> Double {
        let hatX: Double
        if let prev = hatXPrev {
            hatX = alpha * x + (1 - alpha) * prev
        } else {
            hatX = x
        }
        hatXPrev = hatX
        rawPrev = x
        return hatX
    }
}

/// One Euro filter for a single scalar signal (Casiez et al. 2012).
nonisolated struct OneEuroFilter {
    private let freq: Double
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff: Double
    private var x = LowPassFilter()
    private var dx = LowPassFilter()

    init(freq: Double, minCutoff: Double = 1.0, beta: Double = 0.0, dCutoff: Double = 1.0) {
        self.freq = max(freq, 1e-6)
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private func alpha(cutoff: Double) -> Double {
        let te = 1.0 / freq
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / te)
    }

    mutating func callAsFunction(_ value: Double) -> Double {
        // Derivative of the signal, low-pass filtered.
        let dValue = (x.rawPrev == nil) ? 0.0 : (value - x.rawPrev!) * freq
        let edValue = dx.filter(dValue, alpha: alpha(cutoff: dCutoff))
        // Adaptive cutoff: more smoothing when still, less when moving fast.
        let cutoff = minCutoff + beta * abs(edValue)
        return x.filter(value, alpha: alpha(cutoff: cutoff))
    }
}

/// Bank of One Euro filters keyed by point name, one filter per coordinate.
/// Direct port of VidCalc.py's PointSmoother.
nonisolated final class PointSmoother {
    private let freq: Double
    private let minCutoff: Double
    private let beta: Double
    private let resetGap: Double
    private var filters: [String: (axes: [OneEuroFilter], lastT: Double)] = [:]

    init(freq: Double, minCutoff: Double = 1.0, beta: Double = 0.3, resetGap: Double = 0.5) {
        self.freq = freq
        self.minCutoff = minCutoff
        self.beta = beta
        self.resetGap = resetGap
    }

    /// Smooth a point (any coordinate count) at time `t` (seconds). Returns
    /// nil if `coords` is nil, matching the Python semantics.
    func smooth(_ name: String, _ coords: [Double]?, at t: Double) -> [Double]? {
        guard let coords else { return nil }
        var entry = filters[name]
        if entry == nil || (t - entry!.lastT) > resetGap {
            entry = (coords.map { _ in
                OneEuroFilter(freq: freq, minCutoff: minCutoff, beta: beta)
            }, t)
        }
        var axes = entry!.axes
        let smoothed = (0..<coords.count).map { i in axes[i](coords[i]) }
        filters[name] = (axes, t)
        return smoothed
    }
}
