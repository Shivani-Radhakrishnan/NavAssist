import ARKit
import BlindNavCore
import CoreML
import Vision

/// Turns camera frames into left / center / right obstacle readings.
protocol ObstacleSource: AnyObject {
    var onReading: ((ZoneReading, TimeInterval) -> Void)? { get set }
    var kind: String { get }
    func process(frame: ARFrame, floorY: Float, heading: Vec2)
}

enum ObstacleSources {
    /// The best detector this phone supports, or nil (with a reason) if there is none.
    static func best(warnDistance: Double) -> (ObstacleSource?, String?) {
        if ARController.hasLiDAR {
            let s = LiDARObstacleSource()
            s.analyzer.warnDistance = warnDistance
            return (s, nil)
        }
        if let s = NeuralObstacleSource.load() { return (s, nil) }
        return (nil, "Obstacle warnings are off: this iPhone has no LiDAR sensor and the depth model "
                + "is not installed. See the README to add it.")
    }
}

// MARK: - LiDAR: real 3-D points

/// iPhone Pro models: ARKit's LiDAR depth map, turned into 3-D points around the user.
/// Real distances, and the floor and ceiling are removed by height.
final class LiDARObstacleSource: ObstacleSource {
    var onReading: ((ZoneReading, TimeInterval) -> Void)?
    var analyzer = MetricZoneAnalyzer()
    let kind = "LiDAR"

    private let queue = DispatchQueue(label: "blindnav.lidar", qos: .userInitiated)
    private var busy = false
    private var last: TimeInterval = 0
    private let stride = 4                 // use every 4th depth pixel (64 x 48 points)

    func process(frame: ARFrame, floorY: Float, heading: Vec2) {
        guard !busy, frame.timestamp - last >= 0.1, let depth = frame.sceneDepth else { return }
        last = frame.timestamp
        busy = true

        // Copy what we need now: ARKit wants frames released quickly.
        let samples = Self.copySamples(depth: depth.depthMap, confidence: depth.confidenceMap, stride: stride)
        let intr = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let cam = frame.camera.transform
        let ts = frame.timestamp
        let analyzer = self.analyzer

        queue.async { [weak self] in
            let sx = Float(samples.width) / Float(res.width)
            let sy = Float(samples.height) / Float(res.height)
            let fx = intr[0][0] * sx, fy = intr[1][1] * sy
            let cx = intr[2][0] * sx, cy = intr[2][1] * sy
            let origin = Vec2(fromWorldX: cam.columns.3.x, z: cam.columns.3.z)
            let right = Vec2(heading.y, -heading.x)

            var points: [ObstaclePoint] = []
            points.reserveCapacity(samples.values.count)
            for s in samples.values {
                // Pixel -> camera space (ARKit camera: x right, y up, looking along -z).
                let x = (s.u - cx) * s.d / fx
                let y = (s.v - cy) * s.d / fy
                let w = cam * SIMD4<Float>(x, -y, -s.d, 1)
                let rel = Vec2(fromWorldX: w.x, z: w.z) - origin
                points.append(ObstaclePoint(lateral: rel.dot(right), forward: rel.dot(heading),
                                            height: Double(w.y - floorY)))
            }
            let reading = analyzer.analyze(points)
            DispatchQueue.main.async {
                self?.busy = false
                self?.onReading?(reading, ts)
            }
        }
    }

    private struct Samples {
        var width = 0, height = 0
        var values: [(u: Float, v: Float, d: Float)] = []
    }

    private static func copySamples(depth: CVPixelBuffer, confidence: CVPixelBuffer?, stride: Int) -> Samples {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        if let c = confidence { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            if let c = confidence { CVPixelBufferUnlockBaseAddress(c, .readOnly) }
        }
        var out = Samples()
        out.width = CVPixelBufferGetWidth(depth)
        out.height = CVPixelBufferGetHeight(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return out }
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        let confBase = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRow = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        for v in Swift.stride(from: 0, to: out.height, by: stride) {
            let row = (base + v * rowBytes).assumingMemoryBound(to: Float32.self)
            let confRowPtr = confBase.map { ($0 + v * confRow).assumingMemoryBound(to: UInt8.self) }
            for u in Swift.stride(from: 0, to: out.width, by: stride) {
                let d = row[u]
                guard d.isFinite, d > 0.1 else { continue }
                // Skip low-confidence pixels (ARConfidenceLevel.low == 0).
                if let c = confRowPtr, c[u] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                out.values.append((Float(u), Float(v), d))
            }
        }
        return out
    }
}

// MARK: - Camera only: neural depth

/// iPhones without LiDAR: Apple's Core ML build of Depth Anything V2 (the same network
/// as step11.py) estimates relative depth from the camera picture.
///
/// The model isn't included in the repository (about 50 MB). Add
/// `DepthAnythingV2SmallF16.mlpackage` to the BlindNav folder; see the README.
final class NeuralObstacleSource: ObstacleSource {
    var onReading: ((ZoneReading, TimeInterval) -> Void)?
    let kind = "camera depth model"

    private let model: VNCoreMLModel
    private let queue = DispatchQueue(label: "blindnav.depth", qos: .userInitiated)
    private var busy = false
    private var last: TimeInterval = 0
    // Only touched on `queue`:
    private var analyzer = RelativeDepthZoneAnalyzer()
    private var nearIsBright: Bool?
    private var votes = 0

    /// Loaded once. `AppServices` touches this on a background queue at launch so the
    /// ~50 MB model isn't loaded on the main thread when navigation starts.
    static let sharedModel: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let ml = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        return try? VNCoreMLModel(for: ml)
    }()

    static func load() -> NeuralObstacleSource? {
        sharedModel.map { NeuralObstacleSource(model: $0) }
    }

    private init(model: VNCoreMLModel) {
        self.model = model
    }

    func process(frame: ARFrame, floorY: Float, heading: Vec2) {
        guard !busy, frame.timestamp - last >= 0.2 else { return }   // about 5 per second
        last = frame.timestamp
        busy = true
        let image = frame.capturedImage
        let ts = frame.timestamp

        queue.async { [weak self] in
            guard let self else { return }
            let reading = self.estimate(image)
            DispatchQueue.main.async {
                self.busy = false
                if let reading { self.onReading?(reading, ts) }
            }
        }
    }

    private func estimate(_ image: CVPixelBuffer) -> ZoneReading? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        // The model wants a landscape 518 x 392 picture, the same shape as the camera's own
        // (landscape) image, so feed it unrotated (no stretching) and rotate the result upright below.
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return nil }

        var grid: (data: [Float], width: Int, height: Int)?
        if let obs = request.results?.first as? VNPixelBufferObservation {
            grid = Self.floats(from: obs.pixelBuffer)
        } else if let obs = request.results?.first as? VNCoreMLFeatureValueObservation,
                  let arr = obs.featureValue.multiArrayValue {
            grid = Self.floats(from: arr)
        }
        guard let raw = grid, raw.width > 0 else { return nil }
        // Phone held upright: turn the landscape result so "up" in the array is up in the world.
        var g = rotateClockwise(raw.data, width: raw.width, height: raw.height)

        // The analyzer expects "bigger = closer". Work out which way this model's output
        // goes from the first frames: the floor at the bottom is nearer than the top.
        if abs(votes) < 10 {
            let top = Self.mean(g.data, g.width, rows: 0..<(g.height / 6))
            let bottom = Self.mean(g.data, g.width, rows: (g.height * 5 / 6)..<g.height)
            votes += bottom > top ? 1 : -1
            nearIsBright = votes >= 0
        }
        if nearIsBright == false {
            let maxV = g.data.max() ?? 1
            g.data = g.data.map { maxV - $0 + 1e-3 }
        }
        return analyzer.analyze(depth: g.data, width: g.width, height: g.height)
    }

    private static func mean(_ d: [Float], _ w: Int, rows: Range<Int>) -> Float {
        var s: Float = 0
        var n = 0
        for y in rows {
            for x in 0..<w { s += d[y * w + x]; n += 1 }
        }
        return n > 0 ? s / Float(n) : 0
    }

    private static func floats(from pb: CVPixelBuffer) -> (data: [Float], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return ([], 0, 0) }
        var out = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
            for y in 0..<h {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
            for y in 0..<h {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
                for x in 0..<w { out[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent16:
            for y in 0..<h {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) }
            }
        default:  // treat as 8-bit grayscale
            for y in 0..<h {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) }
            }
        }
        return (out, w, h)
    }

    private static func floats(from arr: MLMultiArray) -> (data: [Float], width: Int, height: Int) {
        let shape = arr.shape.map(\.intValue)
        guard shape.count >= 2 else { return ([], 0, 0) }
        let h = shape[shape.count - 2], w = shape[shape.count - 1]
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { out[i] = arr[i].floatValue }
        return (out, w, h)
    }
}
