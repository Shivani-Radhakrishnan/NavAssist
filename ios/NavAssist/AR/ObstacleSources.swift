import ARKit
import NavAssistCore
import CoreML
import Vision

/// Turns camera frames into obstacle readings plus scene hints (doors, stairs).
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
        if let s = NeuralObstacleSource.load() {
            s.analyzer.warnDistance = min(warnDistance, 1.3)   // camera estimates: don't shout from far away
            return (s, nil)
        }
        return (nil, "Obstacle warnings are off: this iPhone has no LiDAR sensor and the depth model "
                + "is not installed. See the README to add it.")
    }
}

// MARK: - Shared pieces

/// What we need from an ARFrame, copied on the main thread so the frame can be released.
struct FrameContext {
    let camera: simd_float4x4
    let intrinsics: simd_float3x3
    let imageSize: CGSize
    let floorY: Float
    let heading: Vec2
    let timestamp: TimeInterval
    /// Meters to a door ARKit has classified, in the walking direction.
    let doorAhead: Double?

    init(frame: ARFrame, floorY: Float, heading: Vec2) {
        camera = frame.camera.transform
        intrinsics = frame.camera.intrinsics
        imageSize = frame.camera.imageResolution
        self.floorY = floorY
        self.heading = heading
        timestamp = frame.timestamp
        doorAhead = Self.door(in: frame, heading: heading)
    }

    /// A world point as seen from the user: how far right, how far ahead, how high off the floor.
    func obstaclePoint(_ w: SIMD4<Float>) -> ObstaclePoint {
        let rel = Vec2(fromWorldX: w.x, z: w.z) - Vec2(fromWorldX: camera.columns.3.x, z: camera.columns.3.z)
        let right = Vec2(heading.y, -heading.x)
        return ObstaclePoint(lateral: rel.dot(right), forward: rel.dot(heading), height: Double(w.y - floorY))
    }

    /// Camera-space point for a pixel of the (landscape) camera image at a given depth.
    func unproject(u: Float, v: Float, depth d: Float) -> SIMD4<Float> {
        let x = (u - intrinsics[2][0]) * d / intrinsics[0][0]
        let y = (v - intrinsics[2][1]) * d / intrinsics[1][1]
        return camera * SIMD4<Float>(x, -y, -d, 1)
    }

    /// ARKit can classify flat surfaces as doors on iPhone XS and later (no LiDAR needed).
    private static func door(in frame: ARFrame, heading: Vec2) -> Double? {
        guard ARPlaneAnchor.isClassificationSupported else { return nil }
        let me = Vec2(fromWorldX: frame.camera.transform.columns.3.x, z: frame.camera.transform.columns.3.z)
        let right = Vec2(heading.y, -heading.x)
        var best: Double?
        for case let plane as ARPlaneAnchor in frame.anchors where plane.alignment == .vertical {
            guard case .door = plane.classification else { continue }
            let c = plane.transform * SIMD4<Float>(plane.center.x, plane.center.y, plane.center.z, 1)
            let rel = Vec2(fromWorldX: c.x, z: c.z) - me
            let ahead = rel.dot(heading), side = rel.dot(right)
            if ahead > 0.3, ahead < 4, abs(side) < 0.8, ahead < (best ?? .infinity) { best = ahead }
        }
        return best
    }
}

/// About once a second: where are doors, door handles and stairs in view?
///
/// With the bundled detector (DoorStairsDetector, trained on Open Images; see training/detector)
/// it finds boxes, which together with depth give "door 2 meters ahead, handle on the right" and
/// "stairs ahead, 3 meters". Without the model it falls back to Apple's image classifier, which
/// only says whether a door or stairs are probably in the picture.
/// Only used from the obstacle source's background queue.
final class SceneClassifier {
    private var last: TimeInterval = 0
    private(set) var door: Float = 0
    private(set) var stairs: Float = 0
    private(set) var detections: [Detection] = []
    private let interpreter = DetectionInterpreter()

    static let detector: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "DoorStairsDetector", withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url, configuration: MLModelConfiguration()) else { return nil }
        return try? VNCoreMLModel(for: ml)
    }()

    func update(_ image: CVPixelBuffer, at t: TimeInterval) {
        guard t - last >= 1.0 else { return }
        last = t
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .right)
        if let model = Self.detector {
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            guard (try? handler.perform([request])) != nil,
                  let results = request.results as? [VNRecognizedObjectObservation] else { return }
            detections = results.compactMap { obs in
                guard let top = obs.labels.first, let kind = Detection.Kind(rawValue: top.identifier) else { return nil }
                let b = obs.boundingBox   // upright image, bottom-left origin
                return Detection(kind: kind, confidence: Double(top.confidence), x: Double(b.minX),
                                 y: Double(1 - b.maxY), width: Double(b.width), height: Double(b.height))
            }
            return
        }
        let request = VNClassifyImageRequest()
        guard (try? handler.perform([request])) != nil, let results = request.results else { return }
        door = results.first { $0.identifier == "door" }?.confidence ?? 0
        stairs = results.first { $0.identifier == "stairs" || $0.identifier == "escalator" }?.confidence ?? 0
    }

    /// `depth(x, y)`: meters at a point of the upright image (normalised, top-left origin).
    func hints(for reading: ZoneReading, doorFromPlanes: Double?, stairs cue: StairCue?,
               depth: ((Double, Double) -> Double?)? = nil) -> SceneHints {
        if Self.detector != nil {
            var hints = interpreter.hints(from: detections, depth: depth ?? { _, _ in nil })
            if hints.doorAhead == nil { hints.doorAhead = doorFromPlanes }
            // A door is seen ahead but its distance is unknown, and something blocks the path: that's the door.
            if hints.doorAhead == nil, reading.danger[Zone.center.rawValue] >= 1,
               detections.contains(where: { $0.kind == .door && $0.confidence >= 0.5 && $0.x < 0.7 && $0.maxX > 0.3 }) {
                hints.doorAhead = reading.meters[Zone.center.rawValue]
            }
            if let cue {   // the floor-profile stair detector measured them: that wins
                hints.stairs = cue
                hints.stairsInView = false
                hints.stairsAhead = nil
            }
            return hints
        }
        var door = doorFromPlanes
        // The classifier sees a door and something is blocking the path: that something is the door.
        if door == nil, self.door > 0.5, reading.danger[Zone.center.rawValue] >= 1 {
            door = reading.meters[Zone.center.rawValue]
        }
        return SceneHints(doorAhead: door, stairs: cue, stairsInView: cue == nil && stairs > 0.6)
    }
}

// MARK: - LiDAR: real 3-D points

/// iPhone Pro models: ARKit's LiDAR depth map, turned into 3-D points around the user.
final class LiDARObstacleSource: ObstacleSource {
    var onReading: ((ZoneReading, TimeInterval) -> Void)?
    var analyzer = MetricZoneAnalyzer()
    let kind = "LiDAR"

    private let queue = DispatchQueue(label: "navassist.lidar", qos: .userInitiated)
    private let classifier = SceneClassifier()
    private let stairs = StairDetector()
    private var busy = false
    private var last: TimeInterval = 0
    private let stride = 4                 // every 4th depth pixel (64 x 48 points)

    func process(frame: ARFrame, floorY: Float, heading: Vec2) {
        guard !busy, frame.timestamp - last >= 0.1, let depth = frame.sceneDepth else { return }
        last = frame.timestamp
        busy = true
        let ctx = FrameContext(frame: frame, floorY: floorY, heading: heading)
        let samples = Self.copySamples(depth: depth.depthMap, confidence: depth.confidenceMap, stride: stride)
        let image = frame.capturedImage
        let analyzer = self.analyzer

        queue.async { [weak self] in
            guard let self else { return }
            let sx = Float(ctx.imageSize.width) / Float(samples.width)
            let sy = Float(ctx.imageSize.height) / Float(samples.height)
            let points = samples.values.map { s in
                ctx.obstaclePoint(ctx.unproject(u: s.u * sx, v: s.v * sy, depth: s.d))
            }
            self.classifier.update(image, at: ctx.timestamp)
            var reading = analyzer.analyze(points)
            let lookup = samples.lookup(stride: self.stride)
            reading.hints = self.classifier.hints(for: reading, doorFromPlanes: ctx.doorAhead,
                                                  stairs: self.stairs.detect(points), depth: lookup)
            DispatchQueue.main.async {
                self.busy = false
                self.onReading?(reading, ctx.timestamp)
            }
        }
    }

    private struct Samples {
        var width = 0, height = 0
        var values: [(u: Float, v: Float, d: Float)] = []

        /// Meters at an upright-image point: the closest confident sample in the 3 x 3 cells around it.
        func lookup(stride: Int) -> (Double, Double) -> Double? {
            let gw = width / stride + 1, gh = height / stride + 1
            var grid = [Float](repeating: .nan, count: gw * gh)
            for s in values { grid[Int(s.v) / stride * gw + Int(s.u) / stride] = s.d }
            let w = Float(width), h = Float(height)
            return { x, y in
                // upright (x, y) -> landscape depth-map pixel (u, v) = (y, 1 - x)
                let gu = Int(Float(y) * w) / stride, gv = Int(Float(1 - x) * h) / stride
                var best = Float.infinity
                for dv in -1...1 {
                    for du in -1...1 {
                        let u = gu + du, v = gv + dv
                        guard u >= 0, u < gw, v >= 0, v < gh else { continue }
                        let d = grid[v * gw + u]
                        if d.isFinite { best = min(best, d) }
                    }
                }
                return best.isFinite ? Double(best) : nil
            }
        }
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
                if let c = confRowPtr, c[u] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                out.values.append((Float(u), Float(v), d))
            }
        }
        return out
    }
}

// MARK: - Camera only: neural depth, put into meters with ARKit's feature points

/// iPhones without LiDAR. Depth Anything V2 (Apple's Core ML build) estimates relative depth;
/// ARKit's tracked feature points, which have real 3-D positions, convert it to meters every
/// frame (see InverseDepthFit). With meters, obstacles get real sizes and positions, so a basket
/// beside the path isn't "ahead", and the floor can be checked for stairs.
final class NeuralObstacleSource: ObstacleSource {
    var onReading: ((ZoneReading, TimeInterval) -> Void)?
    var analyzer = MetricZoneAnalyzer()
    let kind = "camera depth model"

    private let model: VNCoreMLModel
    private let queue = DispatchQueue(label: "navassist.depth", qos: .userInitiated)
    private let classifier = SceneClassifier()
    private let stairs = StairDetector()
    private var busy = false
    private var last: TimeInterval = 0
    // Only touched on `queue`:
    private var fallback: RelativeDepthZoneAnalyzer = {
        var a = RelativeDepthZoneAnalyzer()
        a.warnRatio = 2.0                  // without meters, only warn about clearly close things
        return a
    }()

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
        let ctx = FrameContext(frame: frame, floorY: floorY, heading: heading)
        let features = frame.rawFeaturePoints?.points ?? []
        let image = frame.capturedImage
        let analyzer = self.analyzer

        queue.async { [weak self] in
            guard let self else { return }
            let reading = self.estimate(image, ctx: ctx, features: features, analyzer: analyzer)
            DispatchQueue.main.async {
                self.busy = false
                if let reading { self.onReading?(reading, ctx.timestamp) }
            }
        }
    }

    private func estimate(_ image: CVPixelBuffer, ctx: FrameContext, features: [simd_float3],
                          analyzer: MetricZoneAnalyzer) -> ZoneReading? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        // The model wants a landscape 518 x 392 picture, the camera's own (landscape) shape.
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNPixelBufferObservation else { return nil }
        let grid = Self.floats(from: obs.pixelBuffer)
        guard grid.width > 0 else { return nil }
        classifier.update(image, at: ctx.timestamp)

        let imgW = Float(ctx.imageSize.width), imgH = Float(ctx.imageSize.height)
        let gw = grid.width, gh = grid.height
        func value(atImage u: Float, _ v: Float) -> Double? {
            let gu = Int(u * Float(gw) / imgW), gv = Int(v * Float(gh) / imgH)
            guard gu >= 0, gu < gw, gv >= 0, gv < gh else { return nil }
            return Double(grid.data[gv * gw + gu])
        }

        // 1. Where do ARKit's feature points land in the picture, and how far away are they?
        let toCamera = ctx.camera.inverse
        var netValues: [Double] = [], meters: [Double] = []
        let fx = ctx.intrinsics[0][0], fy = ctx.intrinsics[1][1], cx = ctx.intrinsics[2][0], cy = ctx.intrinsics[2][1]
        for p in features {
            let c = toCamera * SIMD4<Float>(p.x, p.y, p.z, 1)
            let z = -c.z
            guard z > 0.2 else { continue }
            let u = fx * c.x / z + cx, v = fy * -c.y / z + cy
            if let r = value(atImage: u, v) {
                netValues.append(r)
                meters.append(Double(z))
            }
        }

        // 2. Fit the conversion; with it, turn the depth picture into 3-D points.
        if let fit = InverseDepthFit.fit(networkValues: netValues, meters: meters) {
            var points: [ObstaclePoint] = []
            points.reserveCapacity((gw / 4) * (gh / 4))
            for gv in stride(from: 0, to: gh, by: 4) {
                for gu in stride(from: 0, to: gw, by: 4) {
                    guard let d = fit.meters(Double(grid.data[gv * gw + gu])), d < 6 else { continue }
                    let u = (Float(gu) + 0.5) * imgW / Float(gw), v = (Float(gv) + 0.5) * imgH / Float(gh)
                    points.append(ctx.obstaclePoint(ctx.unproject(u: u, v: v, depth: Float(d))))
                }
            }
            var reading = analyzer.analyze(points)
            let lookup: (Double, Double) -> Double? = { x, y in
                // upright (x, y) -> landscape camera pixel (u, v) = (y, 1 - x)
                value(atImage: Float(y) * imgW, Float(1 - x) * imgH).flatMap { fit.meters($0) }
            }
            reading.hints = classifier.hints(for: reading, doorFromPlanes: ctx.doorAhead,
                                             stairs: stairs.detect(points), depth: lookup)
            return reading
        }

        // 3. Not enough tracked points (blank wall, dark room): relative depth only, ahead only.
        let upright = rotateClockwise(grid.data, width: gw, height: gh)
        var reading = fallback.analyze(depth: upright.data, width: upright.width, height: upright.height, time: ctx.timestamp)
        reading.danger[Zone.left.rawValue] = 0
        reading.danger[Zone.right.rawValue] = 0
        reading.hints = classifier.hints(for: reading, doorFromPlanes: ctx.doorAhead, stairs: nil)
        return reading
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
        default:  // treat as 8-bit grayscale
            for y in 0..<h {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) }
            }
        }
        return (out, w, h)
    }
}
