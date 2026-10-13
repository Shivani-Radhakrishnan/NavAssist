// The trained detector through Vision, the way the app runs it, on the held-out test images:
// speed (Mac; see README for the device) and precision / recall at the app's own confidence
// thresholds (DetectionInterpreter: door 0.5, door handle 0.35, stairs 0.5), a detection
// counting as correct when it overlaps a labelled box of its class with IoU >= 0.5.
//
//   swift training/detector/benchmark.swift training/detector/output/DoorStairsDetector.mlmodel
import AppKit
import CoreML
import Foundation
import Vision

let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let compiled = try MLModel.compileModel(at: modelURL)
let testDir = URL(fileURLWithPath: NSHomeDirectory() + "/.cache/navassist/openimages/test")
let images = try FileManager.default.contentsOfDirectory(at: testDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
let thresholds: [String: Float] = ["door": 0.5, "door handle": 0.35, "stairs": 0.5]

struct Annotation: Decodable {
    struct Box: Decodable { let label: String; let coordinates: [String: Double] }
    let image: String
    let annotations: [Box]
}
let truth = Dictionary(uniqueKeysWithValues: try JSONDecoder().decode(
    [Annotation].self, from: Data(contentsOf: testDir.appendingPathComponent("annotations.json"))).map { ($0.image, $0.annotations) })

/// Labelled boxes as normalised rects with a bottom-left origin (Vision's convention).
func labelled(_ name: String, width: Double, height: Double) -> [(String, CGRect)] {
    (truth[name] ?? []).map { a in
        let c = a.coordinates, w = c["width"]! / width, h = c["height"]! / height
        return (a.label, CGRect(x: c["x"]! / width - w / 2, y: 1 - c["y"]! / height - h / 2, width: w, height: h))
    }
}

func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let inter = Double(i.width * i.height)
    return inter / Double(a.width * a.height + b.width * b.height - i.width * i.height)
}
var tp: [String: Int] = [:], fp: [String: Int] = [:], fn: [String: Int] = [:]

var results: [String: Any] = [:]
for (name, units) in [("cpu", MLComputeUnits.cpuOnly), ("all", MLComputeUnits.all)] {
    let config = MLModelConfiguration()
    config.computeUnits = units
    let model = try VNCoreMLModel(for: try MLModel(contentsOf: compiled, configuration: config))
    var times: [Double] = []
    for (i, url) in images.enumerated() {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(url: url)
        let t = Date()
        try handler.perform([request])
        if i >= 5 { times.append(Date().timeIntervalSince(t) * 1000) }   // skip warm-up
        guard name == "all" else { continue }
        // accuracy at the app's thresholds (counted once, on the "all" pass)
        let size = (NSImage(contentsOf: url)?.representations.first).map { (Double($0.pixelsWide), Double($0.pixelsHigh)) } ?? (1, 1)
        var gold = labelled(url.lastPathComponent, width: size.0, height: size.1)
        let found = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { o -> (String, CGRect)? in
            guard let top = o.labels.first, top.confidence >= thresholds[top.identifier, default: 0.5] else { return nil }
            return (top.identifier, o.boundingBox)
        }
        for (label, box) in found {
            if let j = gold.indices.filter({ gold[$0].0 == label }).max(by: { iou(gold[$0].1, box) < iou(gold[$1].1, box) }),
               iou(gold[j].1, box) >= 0.5 {
                tp[label, default: 0] += 1
                gold.remove(at: j)
            } else {
                fp[label, default: 0] += 1
            }
        }
        for (label, _) in gold { fn[label, default: 0] += 1 }
    }
    times.sort()
    results[name] = ["median_ms": times[times.count / 2], "p90_ms": times[Int(Double(times.count) * 0.9)],
                     "images": times.count]
}
for label in thresholds.keys.sorted() {
    let t = Double(tp[label, default: 0]), f = Double(fp[label, default: 0]), n = Double(fn[label, default: 0])
    results["at_app_thresholds_\(label)"] = ["precision": t / max(t + f, 1), "recall": t / max(t + n, 1),
                                              "true_pos": Int(t), "false_pos": Int(f), "missed": Int(n)]
}
let size = (try FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.intValue ?? 0
results["model_megabytes"] = Double(size) / 1_000_000
let json = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
