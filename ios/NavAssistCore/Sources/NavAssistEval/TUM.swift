import CoreGraphics
import CoreML
import Foundation
import ImageIO
import NavAssistCore
import Vision

/// One frame of a TUM RGB-D sequence: color image, true depth, and the motion-capture pose.
struct TUMFrame {
    let index: Int
    let rgb: CGImage
    /// Meters, row-major, 0 = no reading.
    let depth: [Float]
    let width: Int
    let height: Int
    /// Camera-to-world rotation (rows) and position. World z is up.
    let rotation: [[Double]]
    let position: [Double]
}

/// Reader for the TUM RGB-D benchmark (https://cvg.cit.tum.de/data/datasets/rgbd-dataset).
struct TUMSequence {
    // freiburg1 camera intrinsics, from the dataset documentation.
    static let fx = 517.3, fy = 516.5, cx = 318.6, cy = 255.3
    static let depthScale: Float = 5000

    let folder: URL
    let rgbList: [(Double, String)]
    let depthList: [(Double, String)]
    let poses: [(Double, [Double])]

    init(_ path: String) throws {
        let folder = URL(fileURLWithPath: path)
        self.folder = folder
        func read(_ name: String) throws -> [(Double, [String])] {
            try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
                .map { line in
                    let p = line.split(separator: " ").map(String.init)
                    return (Double(p[0])!, Array(p.dropFirst()))
                }
        }
        rgbList = try read("rgb.txt").map { ($0.0, $0.1[0]) }
        depthList = try read("depth.txt").map { ($0.0, $0.1[0]) }
        poses = try read("groundtruth.txt").map { ($0.0, $0.1.map { Double($0)! }) }
    }

    var count: Int { rgbList.count }

    func frame(_ i: Int) -> TUMFrame? {
        let t = rgbList[i].0
        let d = depthList.min { abs($0.0 - t) < abs($1.0 - t) }!
        let g = poses.min { abs($0.0 - t) < abs($1.0 - t) }!
        guard abs(d.0 - t) < 0.03, abs(g.0 - t) < 0.03,
              let rgb = Self.load(folder.appendingPathComponent(rgbList[i].1)),
              let depthImage = Self.load(folder.appendingPathComponent(d.1)) else { return nil }
        let (w, h) = (depthImage.width, depthImage.height)
        var raw = [UInt16](repeating: 0, count: w * h)
        let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 2,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.draw(depthImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = g.1
        let (qx, qy, qz, qw) = (p[3], p[4], p[5], p[6])
        let r = [
            [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
            [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
            [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
        ]
        return TUMFrame(index: i, rgb: rgb, depth: raw.map { Float($0) / Self.depthScale },
                        width: w, height: h, rotation: r, position: [p[0], p[1], p[2]])
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

extension TUMFrame {
    /// World point for a pixel at a given depth (TUM camera: x right, y down, z forward).
    func world(u: Double, v: Double, depth d: Double) -> [Double] {
        let c = [(u - TUMSequence.cx) * d / TUMSequence.fx, (v - TUMSequence.cy) * d / TUMSequence.fy, d]
        return (0..<3).map { i in rotation[i][0] * c[0] + rotation[i][1] * c[1] + rotation[i][2] * c[2] + position[i] }
    }

    /// The camera's forward direction on the floor plane, as the app's heading.
    var heading: Vec2 {
        Vec2(rotation[0][2], rotation[1][2]).normalized
    }

    /// A world point relative to the walker, as the app sees obstacles.
    func obstaclePoint(_ w: [Double], floorZ: Double) -> ObstaclePoint {
        let h = heading
        let rel = Vec2(w[0] - position[0], w[1] - position[1])
        let right = Vec2(h.y, -h.x)
        return ObstaclePoint(lateral: rel.dot(right), forward: rel.dot(h), height: w[2] - floorZ)
    }
}

/// The app's Core ML depth model, run the same way the app runs it.
struct DepthModel {
    let model: VNCoreMLModel

    init(compiledModel path: String) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try VNCoreMLModel(for: MLModel(contentsOf: URL(fileURLWithPath: path), configuration: config))
    }

    /// Relative inverse depth (bigger = closer) at the model's 518 x 392 resolution.
    func predict(_ image: CGImage) throws -> (data: [Float], width: Int, height: Int) {
        let req = VNCoreMLRequest(model: model)
        req.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([req])
        guard let pb = (req.results?.first as? VNPixelBufferObservation)?.pixelBuffer else {
            throw NSError(domain: "DepthModel", code: 1)
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * rb).assumingMemoryBound(to: Float16.self)
            for x in 0..<w { out[y * w + x] = Float(row[x]) }
        }
        return (out, w, h)
    }
}
