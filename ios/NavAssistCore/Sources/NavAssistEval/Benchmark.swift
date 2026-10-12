import CoreGraphics
import Foundation
import ImageIO
import NavAssistCore
import UniformTypeIdentifiers

/// Deterministic random numbers, so every run of the benchmark gives the same numbers.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Simple CSV writer.
final class CSV {
    private var text: String
    let url: URL
    init(_ url: URL, header: [String]) {
        self.url = url
        text = header.joined(separator: ",") + "\n"
    }
    func row(_ values: [Any]) {
        text += values.map { v -> String in
            if let d = v as? Double { return d.isFinite ? String(format: "%.5f", d) : "" }
            if let o = v as? Double? { return o.map { String(format: "%.5f", $0) } ?? "" }
            if let b = v as? Bool { return b ? "1" : "0" }
            return "\(v)"
        }.joined(separator: ",") + "\n"
    }
    func save() throws { try text.write(to: url, atomically: true, encoding: .utf8) }
}

/// Standard monocular-depth metrics over (estimate, truth) pairs in meters.
struct DepthMetrics {
    var absRel = 0.0, rmse = 0.0, delta1 = 0.0, medianAbs = 0.0, n = 0

    init(_ pairs: [(est: Double, gt: Double)]) {
        guard !pairs.isEmpty else { return }
        n = pairs.count
        var abs: [Double] = []
        var se = 0.0, rel = 0.0, good = 0
        for p in pairs {
            let e = Swift.abs(p.est - p.gt)
            abs.append(e)
            se += e * e
            rel += e / p.gt
            if max(p.est / p.gt, p.gt / p.est) < 1.25 { good += 1 }
        }
        abs.sort()
        absRel = rel / Double(n)
        rmse = (se / Double(n)).squareRoot()
        delta1 = Double(good) / Double(n)
        medianAbs = abs[n / 2]
    }
}

/// Runs the camera-only depth pipeline and the obstacle analyzers on a TUM sequence.
struct TUMBenchmark {
    let seq: TUMSequence
    let model: DepthModel
    let out: URL
    let frameStride: Int

    func run() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rng = SplitMix64(seed: 42)

        // Floor height: 1st percentile of true world heights over a spread of frames.
        var zs: [Double] = []
        for i in Swift.stride(from: 0, to: seq.count, by: max(1, seq.count / 15)) {
            guard let f = seq.frame(i) else { continue }
            for v in Swift.stride(from: 0, to: f.height, by: 8) {
                for u in Swift.stride(from: 0, to: f.width, by: 8) where f.depth[v * f.width + u] > 0 {
                    zs.append(f.world(u: Double(u), v: Double(v), depth: Double(f.depth[v * f.width + u]))[2])
                }
            }
        }
        zs.sort()
        let floorZ = zs[zs.count / 100]
        print(String(format: "floor height estimate: %.3f m", floorZ))

        let perFrame = CSV(out.appendingPathComponent("depth_per_frame.csv"),
                           header: ["frame", "method", "points_used", "fit_r2", "abs_rel", "rmse", "delta1", "median_abs_m", "pixels"])
        let byDistance = CSV(out.appendingPathComponent("depth_error_by_distance.csv"),
                             header: ["true_depth_bin_m", "method", "median_abs_m", "abs_rel", "pixels"])
        let ablation = CSV(out.appendingPathComponent("ablation_points_noise.csv"),
                           header: ["frame", "points", "noise", "fit_ok", "abs_rel", "delta1"])
        let obstacles = CSV(out.appendingPathComponent("obstacle_zones.csv"),
                            header: ["frame", "gt_left", "gt_center", "gt_right", "gt_center_m",
                                     "metric_left", "metric_center", "metric_right", "metric_center_m",
                                     "relative_left", "relative_center", "relative_right"])
        let samples = CSV(out.appendingPathComponent("qualitative_frames.csv"), header: ["frame", "rgb", "true_depth", "estimated_depth_png"])

        var globalFit: InverseDepthFit?
        var binsPerFrame: [String: [Int: [(Double, Double)]]] = ["per_frame_fit": [:], "global_fit": [:]]
        var relative = RelativeDepthZoneAnalyzer()       // the original method (step 11 / first app version)
        let metricAnalyzer = MetricZoneAnalyzer()
        let frames = Array(Swift.stride(from: 0, to: seq.count, by: frameStride))
        let qualitative = Set([frames.count / 8, frames.count * 3 / 8, frames.count * 5 / 8, frames.count * 7 / 8].map { frames[$0] })

        for (k, i) in frames.enumerated() {
            guard let f = seq.frame(i) else { continue }
            let net = try model.predict(f.rgb)
            func netAt(_ u: Int, _ v: Int) -> Double {
                Double(net.data[min(v * net.height / f.height, net.height - 1) * net.width + min(u * net.width / f.width, net.width - 1)])
            }
            var valid: [(u: Int, v: Int, d: Double)] = []
            for v in Swift.stride(from: 0, to: f.height, by: 2) {
                for u in Swift.stride(from: 0, to: f.width, by: 2) {
                    let d = Double(f.depth[v * f.width + u])
                    if d > 0.2 && d < 8 { valid.append((u, v, d)) }
                }
            }
            guard valid.count > 500 else { continue }

            // Sparse "ARKit feature points": random pixels with true depth plus noise.
            func sparseFit(points n: Int, noise: Double) -> InverseDepthFit? {
                var r: [Double] = [], m: [Double] = []
                for _ in 0..<n {
                    let p = valid[Int.random(in: 0..<valid.count, using: &rng)]
                    r.append(netAt(p.u, p.v))
                    m.append(p.d * (1 + Double.random(in: -noise...noise, using: &rng)))
                }
                return InverseDepthFit.fit(networkValues: r, meters: m, minPoints: min(12, n))
            }
            let eval = valid.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
            func pairs(_ fit: InverseDepthFit) -> [(est: Double, gt: Double)] {
                eval.compactMap { p in fit.meters(netAt(p.u, p.v)).map { ($0, p.d) } }
            }

            let fit = sparseFit(points: 200, noise: 0.03)
            if globalFit == nil { globalFit = fit }       // baseline: one conversion for the whole sequence
            for (name, maybe) in [("per_frame_fit", fit), ("global_fit", globalFit)] {
                guard let ft = maybe else {
                    perFrame.row([i, name, 0, Double.nan, Double.nan, Double.nan, Double.nan, Double.nan, 0])
                    continue
                }
                let pr = pairs(ft)
                let m = DepthMetrics(pr)
                perFrame.row([i, name, ft.pointsUsed, ft.r2, m.absRel, m.rmse, m.delta1, m.medianAbs, m.n])
                for p in pr { binsPerFrame[name]![min(Int(p.gt / 0.5), 9), default: []].append((p.est, p.gt)) }
            }

            for n in [10, 25, 50, 100, 200, 400] {
                for noise in [0.0, 0.03, 0.10] {
                    if let ft = sparseFit(points: n, noise: noise) {
                        let m = DepthMetrics(pairs(ft))
                        ablation.row([i, n, noise, true, m.absRel, m.delta1])
                    } else {
                        ablation.row([i, n, noise, false, Double.nan, Double.nan])
                    }
                }
            }

            // Obstacles: ground truth from true depth vs the app's two methods.
            var gtPts: [ObstaclePoint] = [], estPts: [ObstaclePoint] = []
            for p in eval {
                gtPts.append(f.obstaclePoint(f.world(u: Double(p.u), v: Double(p.v), depth: p.d), floorZ: floorZ))
                if let ft = fit, let e = ft.meters(netAt(p.u, p.v)), e < 6 {
                    estPts.append(f.obstaclePoint(f.world(u: Double(p.u), v: Double(p.v), depth: e), floorZ: floorZ))
                }
            }
            let gt = metricAnalyzer.analyze(gtPts)
            let est = metricAnalyzer.analyze(estPts)
            let rel = relative.analyze(depth: net.data, width: net.width, height: net.height)
            var row: [Any] = [i]
            for r in [gt, est] {
                row += r.danger.map { $0 >= 1 } as [Any]
                row.append(r.meters[1] ?? Double.nan)
            }
            row += rel.danger.map { $0 >= 1 } as [Any]
            obstacles.row(row)

            if qualitative.contains(i), let ft = fit {
                let name = String(format: "estimated_depth_%04d.png", i)
                try writeDepthPNG(f, net: netAt, fit: ft, to: out.appendingPathComponent(name))
                let rgbName = seq.rgbList[i].1
                let depthName = seq.depthList.min { abs($0.0 - seq.rgbList[i].0) < abs($1.0 - seq.rgbList[i].0) }!.1
                samples.row([i, rgbName, depthName, name])
            }
            if k % 20 == 0 { print("frame \(i) (\(k + 1)/\(frames.count))") }
        }

        for (name, bins) in binsPerFrame {
            for bin in bins.keys.sorted() {
                let m = DepthMetrics(bins[bin]!.map { ($0.0, $0.1) })
                byDistance.row([Double(bin) * 0.5 + 0.25, name, m.medianAbs, m.absRel, m.n])
            }
        }
        for c in [perFrame, byDistance, ablation, obstacles, samples] { try c.save() }
        print("wrote results to \(out.path)")
    }

    /// Estimated depth at the camera resolution, as a 16-bit PNG in millimeters (0 = none).
    private func writeDepthPNG(_ f: TUMFrame, net: (Int, Int) -> Double, fit: InverseDepthFit, to url: URL) throws {
        var mm = [UInt16](repeating: 0, count: f.width * f.height)
        for v in 0..<f.height {
            for u in 0..<f.width {
                if let m = fit.meters(net(u, v)), m < 10 { mm[v * f.width + u] = UInt16(m * 1000) }
            }
        }
        let data = mm.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        let provider = CGDataProvider(data: data)!
        let img = CGImage(width: f.width, height: f.height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: f.width * 2,
                          space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "PNG", code: 1) }
    }
}
