// Train the door / door-handle / stairs detector with Create ML and evaluate it.
//
//   swift training/detector/train.swift <algorithm> <iterations> [--test]
//     algorithm: objectprint (transfer learning on Apple's object feature print) | yolo (full training)
//
// Data comes from fetch_openimages.py (~/.cache/navassist/openimages/{train,validation,test}).
// The validation split is used to compare settings; `--test` also scores the held-out test
// split and writes the model. Results go to training/detector/results/<name>.json.
import CreateML
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let iterations = Int(args[2]) else {
    print("usage: swift train.swift <objectprint|yolo> <iterations> [--test]")
    exit(2)
}
let algorithmName = args[1]
let scoreTest = args.contains("--test")
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENIMAGES_DIR"]
    ?? NSHomeDirectory() + "/.cache/navassist/openimages")
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func source(_ split: String) -> MLObjectDetector.DataSource {
    .directoryWithImagesAndJsonAnnotation(at: root.appendingPathComponent(split))
}

let algorithm: MLObjectDetector.ModelParameters.ModelAlgorithmType =
    algorithmName == "yolo" ? .darknetYolo : .transferLearning(.objectPrint(revision: 1))
let parameters = MLObjectDetector.ModelParameters(
    validation: .dataSource(source("validation")), batchSize: 32, maxIterations: iterations,
    gridSize: CGSize(width: 13, height: 13), algorithm: algorithm)

let start = Date()
let detector = try MLObjectDetector(trainingData: source("train"), parameters: parameters,
                                    annotationType: .boundingBox(units: .pixel, origin: .topLeft, anchor: .center))
let seconds = Date().timeIntervalSince(start)

func summary(_ m: MLObjectDetectorMetrics) -> [String: Any] {
    ["mAP50": m.meanAveragePrecision.IoU50, "mAP50_95": m.meanAveragePrecision.variedIoU,
     "AP50": m.averagePrecision.IoU50, "AP50_95": m.averagePrecision.variedIoU]
}

var result: [String: Any] = [
    "algorithm": algorithmName, "iterations": iterations, "training_seconds": Int(seconds),
    "train": summary(detector.trainingMetrics), "validation": summary(detector.validationMetrics),
]
let name = "\(algorithmName)-\(iterations)"
if scoreTest {
    let test = detector.evaluation(on: source("test"))
    result["test"] = summary(test)
    let models = here.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    let metadata = MLModelMetadata(
        author: "NavAssist", shortDescription: "Detects doors, door handles and stairs (Open Images V7, CC BY).",
        license: "MIT (model). Training data: Open Images V7 annotations CC BY 4.0, images CC BY 2.0.",
        version: "1.0")
    try detector.write(to: models.appendingPathComponent("DoorStairsDetector.mlmodel"), metadata: metadata)
}
let out = here.appendingPathComponent("results")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try json.write(to: out.appendingPathComponent("\(name).json"))
print(String(data: json, encoding: .utf8)!)
