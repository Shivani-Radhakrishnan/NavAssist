// Offline check of the camera-only depth pipeline on the TUM RGB-D dataset: simulate ~200 ARKit
// feature points from the true depth (with 3% noise), fit network value = a/meters + b, and measure
// the error of the converted depth everywhere else in the frame.
//   xcrun swiftc -O analysis/metric_depth_check.swift -o /tmp/mdc
//   /tmp/mdc <path to DepthAnythingV2SmallF16.mlmodelc> prototype/rgbd_dataset_freiburg1_room

import CoreML
import Vision
import AppKit
// Usage: metric_check <model.mlmodelc> <dataset dir>
let a = CommandLine.arguments
let model = try VNCoreMLModel(for: MLModel(contentsOf: URL(fileURLWithPath: a[1])))
let dir = a[2]
func lines(_ f: String) -> [[String]] { (try! String(contentsOfFile: dir + "/" + f, encoding: .utf8)).split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: " ").map(String.init) } }
let rgb = lines("rgb.txt"), dep = lines("depth.txt")
let depT = dep.map { Double($0[0])! }
func gray16(_ path: String) -> (data: [UInt16], w: Int, h: Int) {
    let img = NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = img.width, h = img.height
    var buf = [UInt16](repeating: 0, count: w * h)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h)
}
func fit(_ r: [Double], _ d: [Double]) -> (Double, Double)? {
    var p = zip(r, d).map { (x: 1 / $0.1, y: $0.0) }
    func solve(_ p: [(x: Double, y: Double)]) -> (Double, Double) {
        let n = Double(p.count), sx = p.reduce(0) { $0 + $1.x }, sy = p.reduce(0) { $0 + $1.y }
        let sxx = p.reduce(0) { $0 + $1.x * $1.x }, sxy = p.reduce(0) { $0 + $1.x * $1.y }
        let a = (n * sxy - sx * sy) / (n * sxx - sx * sx); return (a, (sy - a * sx) / n)
    }
    var (A, B) = solve(p)
    for _ in 0..<2 { p.sort { abs($0.y - (A * $0.x + B)) < abs($1.y - (A * $1.x + B)) }; p = Array(p.prefix(Int(Double(p.count) * 0.75))); (A, B) = solve(p) }
    return A > 0 ? (A, B) : nil
}
var rng = SystemRandomNumberGenerator()
var allErr: [Double] = [], within: [Bool] = [], nearErr: [Double] = []
for k in stride(from: 50, to: rgb.count, by: rgb.count / 12) {
    let t = Double(rgb[k][0])!
    let di = depT.indices.min { abs(depT[$0] - t) < abs(depT[$1] - t) }!
    let depth = gray16(dir + "/" + dep[di][1])
    let img = NSImage(contentsOfFile: dir + "/" + rgb[k][1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let req = VNCoreMLRequest(model: model); req.imageCropAndScaleOption = .scaleFill
    try VNImageRequestHandler(cgImage: img, orientation: .up).perform([req])
    let pb = (req.results!.first as! VNPixelBufferObservation).pixelBuffer
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let gw = CVPixelBufferGetWidth(pb), gh = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!
    func net(_ u: Int, _ v: Int) -> Double { let gu = u * gw / depth.w, gv = v * gh / depth.h; return Double((base + gv * rb).assumingMemoryBound(to: Float16.self)[gu]) }
    func truth(_ u: Int, _ v: Int) -> Double? { let z = depth.data[v * depth.w + u]; return z > 0 ? Double(z) / 5000 : nil }
    // ~200 sparse "ARKit feature points" with known depth
    var r: [Double] = [], d: [Double] = []
    while r.count < 200 { let u = Int.random(in: 0..<depth.w, using: &rng), v = Int.random(in: 0..<depth.h, using: &rng); if let z = truth(u, v) { r.append(net(u, v)); d.append(z * Double.random(in: 0.97...1.03, using: &rng)) } }
    guard let (A, B) = fit(r, d) else { print("frame \(k): fit failed"); continue }
    var fe: [Double] = []
    for v in stride(from: 0, to: depth.h, by: 8) { for u in stride(from: 0, to: depth.w, by: 8) {
        guard let z = truth(u, v) else { continue }
        let inv = (net(u, v) - B) / A; guard inv > 0.05 else { continue }
        let e = abs(1 / inv - z); fe.append(e); allErr.append(e); within.append(e / z < 0.2); if z < 2 { nearErr.append(e) }
    } }
    fe.sort(); print(String(format: "frame %4d: median error %.2f m", k, fe[fe.count / 2]))
}
allErr.sort(); nearErr.sort()
print(String(format: "\nALL: median abs error %.2f m, within 20%% of true depth: %.0f%%;  objects closer than 2 m: median error %.2f m",
             allErr[allErr.count / 2], Double(within.filter { $0 }.count) / Double(within.count) * 100, nearErr[nearErr.count / 2]))
