//
//  VideoPoseAnalyzer.swift
//  TUS-RISE
//
//  Step 3 of the iOS port: run Apple Vision's 3D body-pose model over an
//  imported video and emit per-frame knee/hip angles in the same shape as
//  VidCalc.py's session export, so the existing charts display them and
//  the numbers can be validated against the Python pipeline on the same
//  clip (tolerance ±3°; trends and rep counts are what must match).
//
//  Rep detection, phases, and calibration come from RulesEngine (step 4).
//  Lumbar/spine angles arrive with SpinePose (step 5).
//

import AVFoundation
import Vision
import simd

nonisolated enum VideoPoseAnalyzerError: LocalizedError {
    case noVideoTrack
    case decodeFailed(String)
    case visionFailed(String)
    case noPersonDetected

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .decodeFailed(let reason): return "Couldn't decode the video: \(reason)"
        case .visionFailed(let reason): return "The pose model couldn't run: \(reason)"
        case .noPersonDetected: return "No person was detected in the video."
        }
    }
}

nonisolated enum VideoPoseAnalyzer {

    /// Analyse every Nth frame — mirrors PROCESS_EVERY_N in VidCalc's CONFIG.
    static let processEveryN = 2

    /// SpinePose stride: run the (heavy) spine model every Nth processed frame
    /// and hold lumbar/trunk between runs. The spine moves slowly and is
    /// One-Euro smoothed, so this ~halves SpinePose cost with no meaningful
    /// accuracy loss.
    static let spineEveryN = 2

    /// Load the SpinePose model once. CoreML compiles it on first use, and
    /// creating the estimator per analysis re-paid that cost every run (why a
    /// re-run felt no faster). nil if the model/onnxruntime is unavailable.
    /// Used serially — the app analyses one video at a time.
    nonisolated(unsafe) private static let sharedSpineEstimator = SpinePoseEstimator()

    /// Decode the video and run 3D body-pose detection frame by frame.
    /// Runs off the main actor; `progress` is called with 0…1.
    @concurrent
    static func analyze(url: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> SessionPayload {
        // fileImporter URLs are security-scoped and may point at a file
        // provider (Files app, iCloud) that AVFoundation can't stream from —
        // copy into our own container and analyse the local copy instead.
        let localURL = try copyIntoSandbox(url)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let asset = AVURLAsset(url: localURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoPoseAnalyzerError.noVideoTrack
        }
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let expectedFrames = max(1.0, Double(fps) * duration.seconds)

        // iPhone videos carry rotation in preferredTransform (same gotcha as
        // OpenCV on Windows). Rather than passing an orientation hint to
        // Vision (unreliable for the 3D request), decode through a video
        // composition that bakes the rotation in — every frame reaches
        // Vision physically upright, portrait or landscape, front or back
        // camera.
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var frames: [FrameSample] = []
        var index = 0
        var lastVisionError: Error?
        // The 3D pose model only runs on real Apple hardware — in the
        // simulator it throws, so we drop to the 2D model after the first
        // failure. 2D also mirrors VidCalc.py's pixel-space math exactly.
        var use3D = true
        // SpinePose (step 5): nil until the onnxruntime package + model are
        // in the app, then supplies lumbar/trunk lean from the spine chain.
        let spineEstimator = Self.sharedSpineEstimator
        // One Euro smoothing on positions before angles — mirrors VidCalc's
        // PointSmoother. freq = analysed frames per second. Without this,
        // keypoint jitter re-crosses the rep thresholds and doubles the count.
        let smoother = PointSmoother(freq: Double(fps) / Double(processEveryN))

        // Half-rate SpinePose state: hold the last lumbar/trunk between runs.
        var lastLumbar: Double?
        var lastTrunk: Double?
        var spineTick = 0

        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            try Task.checkCancellation()
            guard index % processEveryN == 0,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            progress(min(1, Double(index) / expectedFrames))
            let t = Double(index) / Double(fps)   // video time in seconds

            var angles: FrameAngles?
            if use3D {
                do {
                    angles = try analyze3D(pixelBuffer, smoother: smoother, t: t)
                } catch {
                    lastVisionError = error
                    use3D = false
                }
            }
            if !use3D {
                do {
                    angles = try analyze2D(pixelBuffer, smoother: smoother, t: t)
                } catch {
                    lastVisionError = error
                    continue
                }
            }
            guard var angles else { continue }   // no person in this frame

            // Spine chain (SpinePose): lumbar = hip->spine_03, trunk =
            // hip->spine_05, both angle-from-vertical in pixel space —
            // identical to VidCalc.py's spine handling. Spine points are
            // smoothed too, keyed "spine_0"…"spine_8".
            if let spineEstimator, let box = angles.bodyBox {
                if spineTick % Self.spineEveryN == 0 {
                    let raw = spineEstimator.spinePoints(in: pixelBuffer,
                                                         personBox: box,
                                                         confidenceThreshold: 0.3)
                    if let raw {
                        let spine: [SIMD2<Float>?] = raw.enumerated().map { i, pt in
                            smooth2(smoother, "spine_\(i)", pt, at: t)
                        }
                        if let hip = spine[0], let lumbarTop = spine[3] {
                            angles.lumbar = AngleMath.angleFromVertical(from: hip, to: lumbarTop)
                        }
                        if let hip = spine[0], let trunkTop = spine[5] {
                            angles.trunk = AngleMath.angleFromVertical(from: hip, to: trunkTop)
                        }
                    }
                    lastLumbar = angles.lumbar
                    lastTrunk = angles.trunk
                } else {
                    // Skipped frame: hold the last spine-derived angles.
                    angles.lumbar = lastLumbar
                    angles.trunk = lastTrunk
                }
                spineTick += 1
            }

            frames.append(FrameSample(frame: index,
                                      knee_angle: angles.knee,
                                      hip_angle: angles.hip,
                                      trunk_lean: angles.trunk,
                                      lumbar_lean: angles.lumbar,
                                      phase: "UNKNOWN",      // filled by RulesEngine below
                                      rep_count: 0,
                                      lumbar_flag: false))
        }
        progress(1)

        // Never finish silently with nothing to show — say why.
        if reader.status == .failed {
            throw VideoPoseAnalyzerError.decodeFailed(reader.error?.localizedDescription ?? "unknown decoder error")
        }
        if frames.isEmpty {
            if let lastVisionError {
                throw VideoPoseAnalyzerError.visionFailed(lastVisionError.localizedDescription)
            }
            throw VideoPoseAnalyzerError.noPersonDetected
        }

        // Step 4: rep detection, phases, calibration, and rules — the same
        // state machine as VidCalc.py, run over the per-frame angles.
        let config = RulesConfig()
        let result = RulesEngine.process(frames: frames,
                                         fps: Double(fps),
                                         processEveryN: processEveryN,
                                         config: config)

        let iso = ISO8601DateFormatter()
        return SessionPayload(schema_version: 1,
                              video: url.lastPathComponent,
                              exercise: "squat",
                              date: iso.string(from: Date()),
                              fps: Double(fps),
                              process_every_n: processEveryN,
                              rep_count: result.repCount,
                              lumbar_baseline: result.lumbarBaseline,
                              trunk_baseline: result.trunkBaseline,
                              lumbar_flex_threshold: config.lumbarFlexThreshold,
                              calibrated: result.calibrated,
                              reps: result.reps,
                              frames: result.frames)
    }

    /// Copy a picked file into the app's temp directory while we hold
    /// security-scoped access, so all later reads are plain local file I/O.
    private static func copyIntoSandbox(_ url: URL) throws -> URL {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: url, to: localURL)
        return localURL
    }

    /// Per-frame result, whichever pose model produced it.
    private struct FrameAngles {
        var knee: Double?
        var hip: Double?
        var trunk: Double?
        var lumbar: Double?
        /// Person bounding box in pixel coords (top-left origin) — SpinePose
        /// is a top-down model and needs it.
        var bodyBox: CGRect?
    }

    /// Vision 3D body pose (17 joints, meters). Device + macOS only.
    /// Returns nil when no person is in the frame; throws if the model can't run.
    /// Frames arrive already upright (rotation baked in during decode).
    private static func analyze3D(_ pixelBuffer: CVPixelBuffer,
                                  smoother: PointSmoother, t: Double) throws -> FrameAngles? {
        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
        try handler.perform([request])
        guard let obs = request.results?.first else { return nil }

        // Same joints as VidCalc (landmarks 11/23/25/27, left side), each
        // One-Euro-smoothed before any angle is computed.
        func pos(_ name: VNHumanBodyPose3DObservation.JointName, _ key: String) -> SIMD3<Float>? {
            guard let point = try? obs.recognizedPoint(name) else { return nil }
            let c = point.position.columns.3
            return smooth3(smoother, key, SIMD3<Float>(c.x, c.y, c.z), at: t)
        }
        let shoulder = pos(.leftShoulder, "l_shoulder"), hip = pos(.leftHip, "l_hip")
        let knee = pos(.leftKnee, "l_knee"), ankle = pos(.leftAnkle, "l_ankle")

        var angles = FrameAngles()
        if let hip, let knee, let ankle {
            angles.knee = AngleMath.jointAngle(at: knee, a: hip, c: ankle)
        }
        if let shoulder, let hip, let knee {
            angles.hip = AngleMath.jointAngle(at: hip, a: shoulder, c: knee)
        }
        if let shoulder, let hip {
            angles.trunk = AngleMath.angleFromVertical(from: hip, to: shoulder)
        }
        guard angles.knee != nil || angles.hip != nil else { return nil }

        // Person box for SpinePose: project all 17 joints back to the image.
        let width = Float(CVPixelBufferGetWidth(pixelBuffer))
        let height = Float(CVPixelBufferGetHeight(pixelBuffer))
        let allJoints: [VNHumanBodyPose3DObservation.JointName] = [
            .topHead, .centerHead, .centerShoulder, .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow, .leftWrist, .rightWrist, .root, .spine,
            .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
        ]
        var pts: [SIMD2<Float>] = []
        for joint in allJoints {
            guard let p = try? obs.pointInImage(joint) else { continue }
            pts.append(SIMD2<Float>(Float(p.x) * width, (1 - Float(p.y)) * height))
        }
        angles.bodyBox = boundingBox(of: pts)
        return angles
    }

    /// Vision 2D body pose fallback — runs everywhere, including the
    /// simulator, and matches VidCalc.py's pixel-space angles most closely.
    private static func analyze2D(_ pixelBuffer: CVPixelBuffer,
                                  smoother: PointSmoother, t: Double) throws -> FrameAngles? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
        try handler.perform([request])
        guard let obs = request.results?.first else { return nil }

        // Vision returns normalized coords (origin bottom-left); convert to
        // pixel coords with y down, like OpenCV, so the math matches the
        // Python pipeline. Frames are already upright from the decoder.
        // Positions are One-Euro-smoothed before angles, like VidCalc.
        let width = Float(CVPixelBufferGetWidth(pixelBuffer))
        let height = Float(CVPixelBufferGetHeight(pixelBuffer))
        func pos(_ name: VNHumanBodyPoseObservation.JointName, _ key: String) -> SIMD2<Float>? {
            guard let point = try? obs.recognizedPoint(name), point.confidence > 0.3 else { return nil }
            let p = SIMD2<Float>(Float(point.location.x) * width,
                                 (1 - Float(point.location.y)) * height)
            return smooth2(smoother, key, p, at: t)
        }
        let shoulder = pos(.leftShoulder, "l_shoulder"), hip = pos(.leftHip, "l_hip")
        let knee = pos(.leftKnee, "l_knee"), ankle = pos(.leftAnkle, "l_ankle")

        var angles = FrameAngles()
        if let hip, let knee, let ankle {
            angles.knee = AngleMath.jointAngle(at: knee, a: hip, c: ankle)
        }
        if let shoulder, let hip, let knee {
            angles.hip = AngleMath.jointAngle(at: hip, a: shoulder, c: knee)
        }
        if let shoulder, let hip {
            angles.trunk = AngleMath.angleFromVertical(from: hip, to: shoulder)
        }
        guard angles.knee != nil || angles.hip != nil else { return nil }

        // Person box for SpinePose from every confident joint.
        if let all = try? obs.recognizedPoints(.all) {
            let pts = all.values.filter { $0.confidence > 0.3 }.map {
                SIMD2<Float>(Float($0.location.x) * width,
                             (1 - Float($0.location.y)) * height)
            }
            angles.bodyBox = boundingBox(of: pts)
        }
        return angles
    }

    /// Smooth a 2D point through the shared PointSmoother (nil passes through).
    private static func smooth2(_ smoother: PointSmoother, _ key: String,
                                _ p: SIMD2<Float>?, at t: Double) -> SIMD2<Float>? {
        guard let s = smoother.smooth(key, p.map { [Double($0.x), Double($0.y)] }, at: t) else { return nil }
        return SIMD2<Float>(Float(s[0]), Float(s[1]))
    }

    /// Smooth a 3D point through the shared PointSmoother (nil passes through).
    private static func smooth3(_ smoother: PointSmoother, _ key: String,
                                _ p: SIMD3<Float>?, at t: Double) -> SIMD3<Float>? {
        guard let s = smoother.smooth(key, p.map { [Double($0.x), Double($0.y), Double($0.z)] }, at: t) else { return nil }
        return SIMD3<Float>(Float(s[0]), Float(s[1]), Float(s[2]))
    }

    /// Axis-aligned box around detected joints (pixel coords, top-left origin).
    private static func boundingBox(of pts: [SIMD2<Float>]) -> CGRect? {
        guard pts.count >= 4 else { return nil }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }
}
