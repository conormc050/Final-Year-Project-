//
//  LiDARTestView.swift
//  TUS-RISE
//
//  Proof of concept: LiDAR depth at spine keypoints. Portrait only.
//  Vision finds neck + root (pelvis), we interpolate 5 points along that
//  line, sample the ARKit depth map at each, and unproject to metres.
//

import SwiftUI
import Combine
import UIKit
import ARKit
import AVFoundation
import Vision
import simd

nonisolated struct CameraIntrinsics: Sendable {
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
}

nonisolated struct DepthSample: Sendable {
    let depth: Float
    let valid: Int
    let high: Int
}

/// How much we trust a keypoint's depth, based on the LiDAR confidence of the pixels sampled.
nonisolated enum DepthQuality: Sendable {
    case good   // most sampled pixels are high-confidence
    case weak   // some valid pixels, but low confidence
    case none   // no valid depth at this point
}

nonisolated struct KeypointDepth: Identifiable, Sendable {
    let id: String
    let pixel: SIMD2<Float>
    /// Normalised (0...1) position in the on-screen preview, for the overlay.
    let screen: SIMD2<Float>?
    /// Camera-space position in metres (x right, y down, z forward along the optical axis).
    let point: SIMD3<Float>?
    let validPixels: Int
    let highPixels: Int
    let poseConfidence: Float

    /// Straight-line distance from the camera to this point, in metres.
    var range: Float? { point.map { simd_length($0) } }

    var quality: DepthQuality {
        guard point != nil else { return .none }
        return highPixels >= 5 ? .good : .weak
    }
}

nonisolated struct LiDARReading: Sendable {
    var keypoints: [KeypointDepth] = []
    var centerDepth: Float?
    var torsoLength: Float?
    var depthSpread: Float?
    var meanRange: Float?
    var depthSize = ""
    var rgbSize = ""
    var milliseconds: Double = 0
    var hertz: Double = 0
    var errorText: String?

    var lockedCount: Int { keypoints.filter { $0.quality == .good }.count }

    static func meters(_ value: Float?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f m", value)
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - s.count)) + s
    }

    func text() -> String {
        if let errorText { return "AR error: \(errorText)" }
        var lines: [String] = []
        lines.append("depth map \(depthSize)   rgb \(rgbSize)")
        lines.append(String(format: "%.1f ms per sample   %.1f Hz", milliseconds, hertz))
        lines.append("centre-of-frame depth: " + Self.meters(centerDepth))
        if keypoints.isEmpty {
            lines.append("no person detected")
            return lines.joined(separator: "\n")
        }
        lines.append("average distance to spine: " + Self.meters(meanRange))
        lines.append("torso neck-to-pelvis (3D): " + Self.meters(torsoLength))
        lines.append("spine depth spread: " + Self.meters(depthSpread))
        lines.append("(values are the median of the last 5 samples)")
        lines.append("")
        lines.append("range = straight-line distance, z = depth along camera axis")
        lines.append("point".padding(toLength: 10, withPad: " ", startingAt: 0)
                     + " " + Self.pad("range", 6) + " " + Self.pad("x", 6) + " " + Self.pad("y", 6)
                     + " " + Self.pad("z", 6) + "  " + Self.pad("px", 2) + "  " + Self.pad("hi", 2))
        for k in keypoints {
            let name = k.id.padding(toLength: 10, withPad: " ", startingAt: 0)
            if let p = k.point, let r = k.range {
                lines.append(name + String(format: " %6.2f %6.2f %6.2f %6.2f  %2d  %2d",
                                           r, p.x, p.y, p.z, k.validPixels, k.highPixels))
            } else {
                lines.append("\(name) no valid depth")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Portrait-only coordinate mapping. The camera sensor is landscape (home-button-right),
/// so Vision is told the image is rotated `.right`, and its normalised output
/// (origin bottom-left, portrait) is mapped back to sensor pixels here.
nonisolated enum PortraitMapping {
    static let vision: CGImagePropertyOrientation = .right

    static func sensorPixel(nx: Float, ny: Float, width: Float, height: Float) -> SIMD2<Float> {
        SIMD2<Float>((1 - ny) * width, (1 - nx) * height)
    }
}

nonisolated enum DepthSampler {
    static func floats(_ buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        var out = [Float](repeating: 0, count: w * h)
        for row in 0..<h {
            let ptr = base.advanced(by: row * stride).assumingMemoryBound(to: Float.self)
            for col in 0..<w { out[row * w + col] = ptr[col] }
        }
        return out
    }

    static func bytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        var out = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let ptr = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for col in 0..<w { out[row * w + col] = ptr[col] }
        }
        return out
    }

    /// Median depth of the (2r+1)² window around (u, v). Zero-confidence pixels are ignored,
    /// and when at least 3 high-confidence pixels exist only those are used.
    static func median(depth: [Float], confidence: [UInt8], width: Int, height: Int,
                       u: Int, v: Int, radius: Int = 1) -> DepthSample? {
        guard width > 0, height > 0, u >= 0, v >= 0, u < width, v < height,
              depth.count >= width * height else { return nil }
        var values: [Float] = []
        var highValues: [Float] = []
        for dv in max(0, v - radius)...min(height - 1, v + radius) {
            for du in max(0, u - radius)...min(width - 1, u + radius) {
                let i = dv * width + du
                let d = depth[i]
                let c: UInt8 = confidence.count > i ? confidence[i] : 2
                if d.isFinite && d > 0 && c >= 1 {
                    values.append(d)
                    if c >= 2 { highValues.append(d) }
                }
            }
        }
        guard !values.isEmpty else { return nil }
        var used = highValues.count >= 3 ? highValues : values
        used.sort()
        return DepthSample(depth: used[used.count / 2], valid: used.count, high: highValues.count)
    }

    static func lift(rgb: SIMD2<Float>, rgbSize: SIMD2<Float>, depth: [Float], confidence: [UInt8],
                     depthWidth: Int, depthHeight: Int,
                     intrinsics k: CameraIntrinsics) -> (point: SIMD3<Float>, sample: DepthSample)? {
        guard rgb.x.isFinite, rgb.y.isFinite, rgbSize.x > 0, rgbSize.y > 0 else { return nil }
        let du = Int(rgb.x * Float(depthWidth) / rgbSize.x)
        let dv = Int(rgb.y * Float(depthHeight) / rgbSize.y)
        guard let s = median(depth: depth, confidence: confidence,
                             width: depthWidth, height: depthHeight, u: du, v: dv) else { return nil }
        let x = (rgb.x - k.cx) * s.depth / k.fx
        let y = (rgb.y - k.cy) * s.depth / k.fy
        return (SIMD3<Float>(x, y, s.depth), s)
    }
}

nonisolated final class LiDARProbe: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session = ARSession()
    var onReading: (@Sendable (LiDARReading) -> Void)?

    private let queue = DispatchQueue(label: "tusrise.lidar.probe")
    private var lastTimestamp: TimeInterval = 0
    private var viewportSize: CGSize = .zero
    /// Last few camera-space points per keypoint, for median smoothing.
    private var history: [String: [SIMD3<Float>]] = [:]
    private static let smoothingWindow = 5

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    /// Size of the on-screen preview so keypoints can be mapped to overlay positions.
    func setViewport(size: CGSize) {
        queue.async { self.viewportSize = size }
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = .smoothedSceneDepth
        config.worldAlignment = .gravity
        queue.async {
            self.history.removeAll()
            self.lastTimestamp = 0
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        var reading = LiDARReading()
        reading.errorText = error.localizedDescription
        onReading?(reading)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let gap = frame.timestamp - lastTimestamp
        guard gap >= 0.1 else { return }
        lastTimestamp = frame.timestamp
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        let started = ProcessInfo.processInfo.systemUptime
        let depth = DepthSampler.floats(sceneDepth.depthMap)
        let confidence = sceneDepth.confidenceMap.map { DepthSampler.bytes($0) } ?? []
        let dw = CVPixelBufferGetWidth(sceneDepth.depthMap)
        let dh = CVPixelBufferGetHeight(sceneDepth.depthMap)
        let rw = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let rh = Float(CVPixelBufferGetHeight(frame.capturedImage))
        let m = frame.camera.intrinsics
        let k = CameraIntrinsics(fx: m[0][0], fy: m[1][1], cx: m[2][0], cy: m[2][1])
        let display: CGAffineTransform? = (viewportSize.width > 0 && viewportSize.height > 0)
            ? frame.displayTransform(for: .portrait, viewportSize: viewportSize)
            : nil

        var reading = LiDARReading()
        reading.depthSize = "\(dw)x\(dh)"
        reading.rgbSize = "\(Int(rw))x\(Int(rh))"
        reading.hertz = gap < 5 ? 1 / gap : 0
        reading.centerDepth = DepthSampler.median(depth: depth, confidence: confidence,
                                                  width: dw, height: dh,
                                                  u: dw / 2, v: dh / 2, radius: 2)?.depth

        let raw = spineKeypoints(buffer: frame.capturedImage,
                                 size: SIMD2<Float>(rw, rh),
                                 display: display,
                                 depth: depth, confidence: confidence,
                                 depthWidth: dw, depthHeight: dh, intrinsics: k)
        reading.keypoints = smooth(raw)

        if let neck = reading.keypoints.first?.point, let pelvis = reading.keypoints.last?.point {
            reading.torsoLength = simd_distance(neck, pelvis)
        }
        let zs = reading.keypoints.compactMap { $0.point?.z }
        if zs.count > 1, let lo = zs.min(), let hi = zs.max() {
            reading.depthSpread = hi - lo
        }
        let ranges = reading.keypoints.compactMap { $0.range }
        if !ranges.isEmpty {
            reading.meanRange = ranges.reduce(0, +) / Float(ranges.count)
        }
        reading.milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        onReading?(reading)
    }

    /// Component-wise median over the last few samples; suppresses single-frame depth flicker.
    private func smooth(_ raw: [KeypointDepth]) -> [KeypointDepth] {
        guard !raw.isEmpty else {
            history.removeAll()
            return raw
        }
        return raw.map { k in
            guard let p = k.point else { return k }
            var h = history[k.id, default: []]
            h.append(p)
            if h.count > Self.smoothingWindow { h.removeFirst() }
            history[k.id] = h
            let smoothed = SIMD3<Float>(Self.median(h.map(\.x)),
                                        Self.median(h.map(\.y)),
                                        Self.median(h.map(\.z)))
            return KeypointDepth(id: k.id, pixel: k.pixel, screen: k.screen, point: smoothed,
                                 validPixels: k.validPixels, highPixels: k.highPixels,
                                 poseConfidence: k.poseConfidence)
        }
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[s.count / 2]
    }

    private func spineKeypoints(buffer: CVPixelBuffer, size: SIMD2<Float>,
                                display: CGAffineTransform?,
                                depth: [Float], confidence: [UInt8],
                                depthWidth: Int, depthHeight: Int,
                                intrinsics: CameraIntrinsics) -> [KeypointDepth] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: PortraitMapping.vision, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all),
              let neck = points[.neck], let root = points[.root],
              neck.confidence > 0.2, root.confidence > 0.2 else { return [] }

        let neckPx = PortraitMapping.sensorPixel(nx: Float(neck.location.x), ny: Float(neck.location.y),
                                                 width: size.x, height: size.y)
        let rootPx = PortraitMapping.sensorPixel(nx: Float(root.location.x), ny: Float(root.location.y),
                                                 width: size.x, height: size.y)
        let confidenceValue = min(neck.confidence, root.confidence)
        let names = ["neck", "spine 25%", "spine 50%", "spine 75%", "pelvis"]
        let steps: [Float] = [0, 0.25, 0.5, 0.75, 1]

        return zip(names, steps).map { name, t in
            let px = neckPx + (rootPx - neckPx) * t
            let lifted = DepthSampler.lift(rgb: px, rgbSize: size, depth: depth, confidence: confidence,
                                           depthWidth: depthWidth, depthHeight: depthHeight,
                                           intrinsics: intrinsics)
            // Sensor pixel -> normalised image coords -> normalised preview coords.
            let screen = display.map { transform -> SIMD2<Float> in
                let q = CGPoint(x: CGFloat(px.x / size.x), y: CGFloat(px.y / size.y)).applying(transform)
                return SIMD2<Float>(Float(q.x), Float(q.y))
            }
            return KeypointDepth(id: name, pixel: px, screen: screen, point: lifted?.point,
                                 validPixels: lifted?.sample.valid ?? 0,
                                 highPixels: lifted?.sample.high ?? 0,
                                 poseConfidence: confidenceValue)
        }
    }
}

nonisolated enum LiDARSelfTest {
    static func run() -> String {
        let w = 256
        let h = 192
        var depth = [Float](repeating: 2.5, count: w * h)
        var confidence = [UInt8](repeating: 2, count: w * h)
        for row in 0..<h { depth[row * w + 99] = 4.0 }
        confidence[96 * w + 101] = 0

        let k = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720)
        let lifted = DepthSampler.lift(rgb: SIMD2<Float>(753, 720), rgbSize: SIMD2<Float>(1920, 1440),
                                       depth: depth, confidence: confidence,
                                       depthWidth: w, depthHeight: h, intrinsics: k)

        let edgeOK = abs((lifted?.point.z ?? 0) - 2.5) < 1e-4
        let countOK = lifted?.sample.valid == 8
        let xOK = abs((lifted?.point.x ?? 0) + 0.345) < 1e-4
        let yOK = abs(lifted?.point.y ?? 1) < 1e-4
        let p = PortraitMapping.sensorPixel(nx: 0.5, ny: 0.9, width: 1920, height: 1440)
        let mapOK = abs(p.x - 192) < 1e-3 && abs(p.y - 720) < 1e-3

        func mark(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }
        return [
            "median rejects background edge: " + mark(edgeOK),
            "low-confidence pixel dropped: " + mark(countOK),
            "unproject X (-0.345 m): " + mark(xOK),
            "unproject Y (0 m): " + mark(yOK),
            "portrait Vision-to-sensor mapping: " + mark(mapOK)
        ].joined(separator: "\n")
    }
}

@MainActor
final class LiDARTestModel: ObservableObject {
    @Published var text = "Tap Start and point the camera at a person 2 to 3 m away."
    @Published var reading = LiDARReading()
    @Published var running = false
    @Published var cameraDenied = false

    let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    let probe = LiDARProbe()

    init() {
        probe.onReading = { [weak self] reading in
            let text = reading.text()
            Task { @MainActor [weak self] in
                self?.text = text
                self?.reading = reading
            }
        }
        if !supported {
            text = "This device has no LiDAR (needs an iPhone Pro or iPad Pro). The self-test still works."
        }
    }

    func toggle() {
        if running {
            stop()
            return
        }
        guard supported else { return }
        Task { await startAfterPermission() }
    }

    /// Ask for camera access explicitly before ARKit touches the camera, so a denied
    /// permission shows a message instead of a dead preview.
    private func startAfterPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var granted = status == .authorized
        if status == .notDetermined {
            granted = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard granted else {
            cameraDenied = true
            text = "Camera access is off. Enable it in Settings > Privacy & Security > Camera > TUS-RISE."
            return
        }
        cameraDenied = false
        probe.start()
        running = true
    }

    func stop() {
        guard running else { return }
        probe.stop()
        running = false
    }

    func selfTest() {
        stop()
        text = LiDARSelfTest.run()
    }

    func copy() {
        UIPasteboard.general.string = text
    }
}

struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

private extension DepthQuality {
    var color: Color {
        switch self {
        case .good: return .green
        case .weak: return .orange
        case .none: return .red
        }
    }
}

/// Draws the spine line, a coloured dot per keypoint and a distance label next to each dot.
struct SpineOverlay: View {
    let keypoints: [KeypointDepth]

    private func position(_ k: KeypointDepth, in size: CGSize) -> CGPoint? {
        guard let s = k.screen, s.x.isFinite, s.y.isFinite else { return nil }
        return CGPoint(x: CGFloat(s.x) * size.width, y: CGFloat(s.y) * size.height)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Path { path in
                    let pts = keypoints.compactMap { position($0, in: size) }
                    guard let first = pts.first else { return }
                    path.move(to: first)
                    pts.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))

                ForEach(keypoints) { k in
                    if let pt = position(k, in: size) {
                        Circle()
                            .fill(k.quality.color)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .frame(width: 16, height: 16)
                            .position(pt)

                        Text(k.range.map { String(format: "%.2f m", $0) } ?? "no depth")
                            .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(k.quality.color.opacity(0.85), in: Capsule())
                            .position(x: min(pt.x + 52, size.width - 36), y: pt.y)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Big, readable summary of the current measurement.
struct DistanceHeadline: View {
    let reading: LiDARReading
    let running: Bool

    private var statusColor: Color {
        guard !reading.keypoints.isEmpty else { return .secondary }
        switch reading.lockedCount {
        case 5: return .green
        case 3...4: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(reading.meanRange.map { String(format: "%.2f m", $0) } ?? "-- m")
                .font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
            Text("average distance from camera to spine")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let err = reading.errorText {
                Text("AR error: \(err)").font(.footnote).foregroundStyle(.red)
            } else if reading.keypoints.isEmpty {
                Text(running ? "No person detected - step back so your torso is in view"
                             : "Tap Start to begin")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Label("\(reading.lockedCount) of \(reading.keypoints.count) points have strong depth",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct LiDARTestView: View {
    @StateObject private var model = LiDARTestModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                DistanceHeadline(reading: model.reading, running: model.running)

                if model.supported {
                    ZStack {
                        ARCameraPreview(session: model.probe.session)
                        SpineOverlay(keypoints: model.reading.keypoints)
                    }
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { model.probe.setViewport(size: geo.size) }
                                .onChange(of: geo.size) { _, size in model.probe.setViewport(size: size) }
                        }
                    )

                    HStack(spacing: 14) {
                        legend(.green, "strong")
                        legend(.orange, "weak")
                        legend(.red, "no depth")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button(model.running ? "Stop" : "Start") { model.toggle() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.supported)
                    Button("Self-test") { model.selfTest() }
                        .buttonStyle(.bordered)
                    Button("Copy") { model.copy() }
                        .buttonStyle(.bordered)
                }

                Text("Hold the phone upright (portrait). Stand 2-3 m away with your torso in view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(model.text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("LiDAR test")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stop() }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label)
        }
    }
}
