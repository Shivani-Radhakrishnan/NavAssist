import ARKit
import BlindNavCore
import Vision

/// Reads signs ("Room 204", "Exit", "Toilets") from the camera with Apple's on-device
/// text recognition, about once every 1.5 seconds. Nothing leaves the phone.
final class SignReader {
    /// Sign texts found in one frame, and the frame's time.
    var onSigns: (([String], TimeInterval) -> Void)?

    private let queue = DispatchQueue(label: "blindnav.signs", qos: .utility)
    private var busy = false
    private var last: TimeInterval = 0

    func process(frame: ARFrame) {
        guard !busy, frame.timestamp - last >= 1.5 else { return }
        // Skip blurry frames taken while turning quickly.
        if case .limited = frame.camera.trackingState { return }
        last = frame.timestamp
        busy = true
        let image = frame.capturedImage
        let ts = frame.timestamp

        queue.async { [weak self] in
            let found = Self.read(image)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if !found.isEmpty { self.onSigns?(found, ts) }
            }
        }
    }

    private static func read(_ image: CVPixelBuffer) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.025          // ignore small print
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .right)
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }

        var out: [String] = []
        for obs in results {
            guard let best = obs.topCandidates(1).first else { continue }
            if let text = SignFilter.clean(best.string, confidence: best.confidence,
                                           relativeHeight: Double(obs.boundingBox.height)),
               !out.contains(text) {
                out.append(text)
            }
        }
        return out
    }
}
