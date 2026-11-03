import SwiftUI
import UIKit
import ARKit
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

nonisolated struct KeypointDepth: Identifiable, Sendable {
    let id: String
    let pixel: SIMD2<Float>
    let point: SIMD3<Float>?
    let validPixels: Int
    let highPixels: Int
    let poseConfidence: Float
}

nonisolated struct LiDARReading: Sendable {
    var keypoints: [KeypointDepth] = []
    var centerDepth: Float?
    var torsoLength: Float?
    var depthSpread: Float?
    var depthSize = ""
    var rgbSize = ""
    var milliseconds: Double = 0
    var hertz: Double = 0
    var errorText: String?

    static func meters(_ value: Float?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f m", value)
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
        lines.append("torso neck-to-pelvis (3D): " + Self.meters(torsoLength))
        lines.append("spine depth spread: " + Self.meters(depthSpread))
        lines.append("")
        lines.append("point       x      y      z    px  hi")
        for k in keypoints {
            let name = k.id.padding(toLength: 10, withPad: " ", startingAt: 0)
            if let p = k.point {
                lines.append(String(format: "%@ %6.2f %6.2f %6.2f  %2d  %2d", name, p.x, p.y, p.z, k.validPixels, k.highPixels))
            } else {
                lines.append("\(name) no valid depth")
            }
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated enum PoseOrientation: String, CaseIterable, Identifiable, Sendable {
    case portrait = "Portrait"
    case landscapeLeft = "Landscape L"
    case landscapeRight = "Landscape R"

    var id: String { rawValue }

    var vision: CGImagePropertyOrientation {
        switch self {
        case .portrait: return .right
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        }
    }

    func sensorPixel(nx: Float, ny: Float, width: Float, height: Float) -> SIMD2<Float> {
        switch self {
        case .portrait: return SIMD2<Float>((1 - ny) * width, (1 - nx) * height)
        case .landscapeLeft: return SIMD2<Float>(nx * width, (1 - ny) * height)
        case .landscapeRight: return SIMD2<Float>((1 - nx) * width, ny * height)
        }
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

    static func median(depth: [Float], confidence: [UInt8], width: Int, height: Int,
                       u: Int, v: Int, radius: Int = 1) -> DepthSample? {
        guard width > 0, height > 0, u >= 0, v >= 0, u < width, v < height,
              depth.count >= width * height else { return nil }
        var values: [Float] = []
        var high = 0
        for dv in max(0, v - radius)...min(height - 1, v + radius) {
            for du in max(0, u - radius)...min(width - 1, u + radius) {
                let i = dv * width + du
                let d = depth[i]
                let c: UInt8 = confidence.count > i ? confidence[i] : 2
                if d.isFinite && d > 0 && c >= 1 {
                    values.append(d)
                    if c >= 2 { high += 1 }
                }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return DepthSample(depth: values[values.count / 2], valid: values.count, high: high)
    }

    static func lift(rgb: SIMD2<Float>, rgbSize: SIMD2<Float>, depth: [Float], confidence: [UInt8],
                     depthWidth: Int, depthHeight: Int,
                     intrinsics k: CameraIntrinsics) -> (point: SIMD3<Float>, sample: DepthSample)? {
        guard rgb.x.isFinite, rgb.y.isFinite else { return nil }
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
    private var orientation: PoseOrientation = .portrait
    private var lastTimestamp: TimeInterval = 0

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func setOrientation(_ value: PoseOrientation) {
        queue.async { self.orientation = value }
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = .smoothedSceneDepth
        config.worldAlignment = .gravity
        session.delegate = self
        session.delegateQueue = queue
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

        var reading = LiDARReading()
        reading.depthSize = "\(dw)x\(dh)"
        reading.rgbSize = "\(Int(rw))x\(Int(rh))"
        reading.hertz = gap < 5 ? 1 / gap : 0
        reading.centerDepth = DepthSampler.median(depth: depth, confidence: confidence,
                                                  width: dw, height: dh,
                                                  u: dw / 2, v: dh / 2, radius: 2)?.depth

        reading.keypoints = spineKeypoints(buffer: frame.capturedImage,
                                           size: SIMD2<Float>(rw, rh),
                                           depth: depth, confidence: confidence,
                                           depthWidth: dw, depthHeight: dh, intrinsics: k)

        if let neck = reading.keypoints.first?.point, let pelvis = reading.keypoints.last?.point {
            reading.torsoLength = simd_distance(neck, pelvis)
        }
        let zs = reading.keypoints.compactMap { $0.point?.z }
        if zs.count > 1, let lo = zs.min(), let hi = zs.max() {
            reading.depthSpread = hi - lo
        }
        reading.milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        onReading?(reading)
    }

    private func spineKeypoints(buffer: CVPixelBuffer, size: SIMD2<Float>,
                                depth: [Float], confidence: [UInt8],
                                depthWidth: Int, depthHeight: Int,
                                intrinsics: CameraIntrinsics) -> [KeypointDepth] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation.vision, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all),
              let neck = points[.neck], let root = points[.root],
              neck.confidence > 0.2, root.confidence > 0.2 else { return [] }

        let neckPx = orientation.sensorPixel(nx: Float(neck.location.x), ny: Float(neck.location.y),
                                             width: size.x, height: size.y)
        let rootPx = orientation.sensorPixel(nx: Float(root.location.x), ny: Float(root.location.y),
                                             width: size.x, height: size.y)
        let confidenceValue = min(neck.confidence, root.confidence)
        let names = ["neck", "spine 25%", "spine 50%", "spine 75%", "pelvis"]
        let steps: [Float] = [0, 0.25, 0.5, 0.75, 1]

        return zip(names, steps).map { name, t in
            let px = neckPx + (rootPx - neckPx) * t
            let lifted = DepthSampler.lift(rgb: px, rgbSize: size, depth: depth, confidence: confidence,
                                           depthWidth: depthWidth, depthHeight: depthHeight,
                                           intrinsics: intrinsics)
            return KeypointDepth(id: name, pixel: px, point: lifted?.point,
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
        let p = PoseOrientation.portrait.sensorPixel(nx: 0.5, ny: 0.9, width: 1920, height: 1440)
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
    @Published var running = false
    @Published var orientation: PoseOrientation = .portrait {
        didSet { probe.setOrientation(orientation) }
    }

    let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    let probe = LiDARProbe()

    init() {
        probe.onReading = { [weak self] reading in
            let text = reading.text()
            Task { @MainActor in self?.text = text }
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
        probe.setOrientation(orientation)
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
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct LiDARTestView: View {
    @StateObject private var model = LiDARTestModel()

    var body: some View {
        VStack(spacing: 10) {
            if model.supported {
                ARCameraPreview(session: model.probe.session)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Picker("Orientation", selection: $model.orientation) {
                ForEach(PoseOrientation.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button(model.running ? "Stop" : "Start") { model.toggle() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.supported)
                Button("Self-test") { model.selfTest() }
                    .buttonStyle(.bordered)
                Button("Copy") { model.copy() }
                    .buttonStyle(.bordered)
            }

            ScrollView {
                Text(model.text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enable)
            }
        }
        .padding()
        .navigationTitle("LiDAR test")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stop() }
    }
}
