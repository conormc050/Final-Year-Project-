//
//  SpinePoseEstimator.swift
//  TUS-RISE
//
//  Step 5 of the iOS port: SpinePose-small (dfki-av, RTMPose-style, 37
//  keypoints incl. 9 spinal) via ONNX Runtime, ported line-for-line from
//  the Python package's inference code (rtmpose.py / pre_processings.py /
//  post_processings.py) so results match VidCalc.py:
//    - bbox -> center/scale with 1.25 padding, aspect fixed to 192/256
//    - crop-pad-resize to 192x256, black padding, no rotation
//    - channels fed in BGR order with mean (123.675, 116.28, 103.53) and
//      std (58.395, 57.12, 57.375) — exactly what the Python pipeline does
//    - SimCC decode: argmax / 2.0, score = mean of x/y maxima
//
//  The whole implementation is compiled out until the onnxruntime Swift
//  package (github.com/microsoft/onnxruntime-swift-package-manager) is
//  added to the project; init() returns nil and the analyzer falls back
//  to body-pose-only angles.
//

import Foundation
import CoreVideo
import CoreImage
import CoreGraphics
import simd

#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#elseif canImport(onnxruntime)
import onnxruntime
#endif

nonisolated final class SpinePoseEstimator {

    /// Indices of the 9 spinal keypoints among SpinePose's 37 — mirrors
    /// estimator.SPINE_IDS in the Python package:
    /// [0]=hip [1..5]=spine_01..spine_05 [6]=neck [7]=neck_02 [8]=neck_03
    /// (VidCalc: LUMBAR_TOP_POS=3 -> spine_03, TRUNK_TOP_POS=5 -> spine_05)
    static let spineIDs = [19, 26, 27, 28, 29, 30, 18, 35, 36]

    static let modelResource = "spinepose-s_32xb256-10e_simspine-256x192"
    static let inputWidth = 192
    static let inputHeight = 256

#if canImport(OnnxRuntimeBindings) || canImport(onnxruntime)

    private let session: ORTSession
    private let inputName: String
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init?() {
        guard let modelURL = Bundle.main.url(forResource: Self.modelResource,
                                             withExtension: "onnx") else { return nil }
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try? options.setGraphOptimizationLevel(.all)

            // Route inference to the Neural Engine / GPU via the CoreML
            // execution provider. CPU-only ORT on an A-series chip blows the
            // real-time budget (per the performance-optimization skill); this
            // is the single biggest win. The model's input is a fixed
            // 1×3×256×192, so static-shape mode lets CoreML claim more nodes.
            // Falls back to CPU if the provider isn't available (e.g. the
            // simulator) — the run still works, just slower.
            var provider = "CPU"
            if ORTIsCoreMLExecutionProviderAvailable() {
                let coreml = ORTCoreMLExecutionProviderOptions()
                coreml.onlyAllowStaticInputShapes = true
                do {
                    try options.appendCoreMLExecutionProvider(with: coreml)
                    provider = "CoreML (ANE/GPU)"
                } catch {
                    provider = "CPU (CoreML append failed: \(error.localizedDescription))"
                }
            }
            #if DEBUG
            print("SpinePose execution provider: \(provider)")
            #endif

            session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            inputName = try session.inputNames().first ?? "input"
        } catch {
            return nil
        }
    }

    /// Runs SpinePose on one frame for the given person box (pixel coords,
    /// top-left origin). Returns the 9 spinal keypoints in pixel coords
    /// (y down, like OpenCV/VidCalc), nil per point below the confidence
    /// threshold, or nil overall if inference fails.
    func spinePoints(in pixelBuffer: CVPixelBuffer,
                     personBox: CGRect,
                     confidenceThreshold: Float) -> [SIMD2<Float>?]? {
        let imgW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imgH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        // ---- bbox_xyxy2cs(padding: 1.25) + aspect fix (top_down_affine) ----
        let center = SIMD2<Float>(Float(personBox.midX), Float(personBox.midY))
        var scaleW = Float(personBox.width) * 1.25
        var scaleH = Float(personBox.height) * 1.25
        let aspect = Float(Self.inputWidth) / Float(Self.inputHeight)
        if scaleW > scaleH * aspect {
            scaleH = scaleW / aspect
        } else {
            scaleW = scaleH * aspect
        }

        // ---- crop-pad-resize to 192x256 (rotation is always 0) ----
        let w = Self.inputWidth, h = Self.inputHeight
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium

        // Map the (top-left-origin) crop rect into CG's bottom-left space.
        let s = CGFloat(Float(w) / scaleW)
        let cropMinX = CGFloat(center.x - scaleW / 2)
        let cropMaxY = CGFloat(center.y + scaleH / 2)
        ctx.draw(cgImage, in: CGRect(x: -cropMinX * s,
                                     y: -(imgH - cropMaxY) * s,
                                     width: imgW * s,
                                     height: imgH * s))

        // ---- normalize: BGR channel order, matching cv2-fed Python ----
        let mean: [Float] = [123.675, 116.28, 103.53]
        let std: [Float] = [58.395, 57.12, 57.375]
        let plane = w * h
        var tensor = [Float](repeating: 0, count: 3 * plane)
        for i in 0..<plane {
            let r = Float(pixels[i * 4])
            let g = Float(pixels[i * 4 + 1])
            let b = Float(pixels[i * 4 + 2])
            tensor[i] = (b - mean[0]) / std[0]
            tensor[plane + i] = (g - mean[1]) / std[1]
            tensor[2 * plane + i] = (r - mean[2]) / std[2]
        }

        // ---- inference ----
        guard let outputs = run(tensor: &tensor, width: w, height: h) else { return nil }
        let (simccX, simccY) = outputs

        // ---- SimCC decode (get_simcc_maximum, split ratio 2.0) ----
        let keypointCount = 37
        let wx = simccX.count / keypointCount
        let wy = simccY.count / keypointCount
        guard wx > 0, wy > 0 else { return nil }

        var result: [SIMD2<Float>?] = []
        result.reserveCapacity(Self.spineIDs.count)
        for k in Self.spineIDs {
            var maxX: Float = -.infinity, maxY: Float = -.infinity
            var locX = 0, locY = 0
            for i in 0..<wx where simccX[k * wx + i] > maxX { maxX = simccX[k * wx + i]; locX = i }
            for i in 0..<wy where simccY[k * wy + i] > maxY { maxY = simccY[k * wy + i]; locY = i }
            let score = 0.5 * (maxX + maxY)
            guard score > confidenceThreshold else { result.append(nil); continue }

            // input-space coords -> original image pixels:
            // kp / input_size * scale + center - scale/2
            let ix = Float(locX) / 2.0
            let iy = Float(locY) / 2.0
            let px = ix / Float(w) * scaleW + center.x - scaleW / 2
            let py = iy / Float(h) * scaleH + center.y - scaleH / 2
            result.append(SIMD2<Float>(px, py))
        }
        return result
    }

    /// Runs the ORT session; returns (simcc_x, simcc_y) as flat float arrays.
    private func run(tensor: inout [Float], width: Int, height: Int) -> ([Float], [Float])? {
        do {
            let data = NSMutableData(bytes: &tensor, length: tensor.count * MemoryLayout<Float>.size)
            let input = try ORTValue(tensorData: data,
                                     elementType: .float,
                                     shape: [1, 3, NSNumber(value: height), NSNumber(value: width)])
            let outputNames = try session.outputNames()
            let outputs = try session.run(withInputs: [inputName: input],
                                          outputNames: Set(outputNames),
                                          runOptions: nil)

            var floatOutputs: [(name: String, values: [Float])] = []
            for name in outputNames {
                guard let value = outputs[name] else { continue }
                let raw = try value.tensorData() as Data
                let floats = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                floatOutputs.append((name, floats))
            }
            guard floatOutputs.count >= 2 else { return nil }

            // Prefer names; otherwise the x head is the smaller one (192*2 < 256*2).
            let xOut = floatOutputs.first { $0.name.lowercased().contains("x") }
            let yOut = floatOutputs.first { $0.name.lowercased().contains("y") }
            if let xOut, let yOut, xOut.name != yOut.name {
                return (xOut.values, yOut.values)
            }
            let sorted = floatOutputs.sorted { $0.values.count < $1.values.count }
            return (sorted[0].values, sorted[1].values)
        } catch {
            return nil
        }
    }

#else

    // onnxruntime package not added to the project yet — estimator disabled.
    init?() { return nil }

    func spinePoints(in pixelBuffer: CVPixelBuffer,
                     personBox: CGRect,
                     confidenceThreshold: Float) -> [SIMD2<Float>?]? { nil }

#endif
}
