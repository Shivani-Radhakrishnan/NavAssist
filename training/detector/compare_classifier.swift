// Does the detector beat what NavAssist used before? Image-level "door in view" / "stairs in
// view" on the held-out test images, for Apple's built-in image classifier at the thresholds
// the app used (door 0.5, stairs 0.6) and for the detector at the app's thresholds (door 0.5,
// stairs 0.5). Ground truth: the image has at least one labelled box of that class.
//
//   swift training/detector/compare_classifier.swift training/detector/output/DoorStairsDetector.mlmodel
import CoreML
import Foundation
import Vision

let model = try VNCoreMLModel(for: try MLModel(contentsOf: try MLModel.compileModel(
    at: URL(fileURLWithPath: CommandLine.arguments[1]))))
let testDir = URL(fileURLWithPath: NSHomeDirectory() + "/.cache/navassist/openimages/test")

struct Annotation: Decodable {
    struct Box: Decodable { let label: String }
    let image: String
    let annotations: [Box]
}
let items = try JSONDecoder().decode([Annotation].self,
                                     from: Data(contentsOf: testDir.appendingPathComponent("annotations.json")))

var counts: [String: [String: Int]] = [:]   // "<system> <class>" -> tp / fp / fn / tn
func add(_ key: String, predicted: Bool, actual: Bool) {
    let cell = predicted ? (actual ? "tp" : "fp") : (actual ? "fn" : "tn")
    counts[key, default: [:]][cell, default: 0] += 1
}

for item in items {
    let url = testDir.appendingPathComponent(item.image)
    let classify = VNClassifyImageRequest()
    let detect = VNCoreMLRequest(model: model)
    detect.imageCropAndScaleOption = .scaleFill
    try VNImageRequestHandler(url: url).perform([classify, detect])
    let labels = classify.results ?? []
    let appleDoor = (labels.first { $0.identifier == "door" }?.confidence ?? 0) > 0.5
    let appleStairs = (labels.first { $0.identifier == "stairs" || $0.identifier == "escalator" }?.confidence ?? 0) > 0.6
    let boxes = (detect.results as? [VNRecognizedObjectObservation] ?? []).compactMap { $0.labels.first }
    let detDoor = boxes.contains { $0.identifier == "door" && $0.confidence >= 0.5 }
    let detStairs = boxes.contains { $0.identifier == "stairs" && $0.confidence >= 0.5 }
    let hasDoor = item.annotations.contains { $0.label == "door" }
    let hasStairs = item.annotations.contains { $0.label == "stairs" }
    add("apple door", predicted: appleDoor, actual: hasDoor)
    add("apple stairs", predicted: appleStairs, actual: hasStairs)
    add("detector door", predicted: detDoor, actual: hasDoor)
    add("detector stairs", predicted: detStairs, actual: hasStairs)
}

var out: [String: Any] = ["images": items.count]
for (key, c) in counts {
    let tp = Double(c["tp", default: 0]), fp = Double(c["fp", default: 0]), fn = Double(c["fn", default: 0])
    out[key] = ["precision": tp / max(tp + fp, 1), "recall": tp / max(tp + fn, 1), "counts": c]
}
let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
