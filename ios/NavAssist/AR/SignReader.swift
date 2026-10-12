import ARKit
import NavAssistCore
import Vision

/// Reads signs ("Room 204", "Exit", "Toilets") from the camera with Apple's on-device
/// text recognition, about once every 1.5 seconds. Nothing leaves the phone.
final class SignReader {
    /// A sign that was read, and the ray from the camera through it, so the app can find where
    /// the sign actually is (not just where the user was standing when it was read).
    struct Sighting {
        let text: String
        let origin: simd_float3
        let direction: simd_float3
    }

    /// Signs found in one frame, and the frame's time.
    var onSigns: (([Sighting], TimeInterval) -> Void)?

    private let queue = DispatchQueue(label: "navassist.signs", qos: .utility)
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
        let camera = frame.camera.transform
        let intr = frame.camera.intrinsics
        let size = frame.camera.imageResolution

        queue.async { [weak self] in
            let found = Self.read(image).map { text, u, v -> Sighting in
                // (u, v): normalised position in the landscape camera image, top-left origin.
                let px = u * Float(size.width), py = v * Float(size.height)
                let dirCam = simd_normalize(SIMD3<Float>((px - intr[2][0]) / intr[0][0], -(py - intr[2][1]) / intr[1][1], -1))
                let world = camera * SIMD4<Float>(dirCam.x, dirCam.y, dirCam.z, 0)
                let c = camera.columns.3
                return Sighting(text: text, origin: SIMD3(c.x, c.y, c.z), direction: simd_normalize(SIMD3(world.x, world.y, world.z)))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if !found.isEmpty { self.onSigns?(found, ts) }
            }
        }
    }

    /// Text found, with its centre in landscape camera-image coordinates (0...1, top-left origin).
    private static func read(_ image: CVPixelBuffer) -> [(String, Float, Float)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.025          // ignore small print
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .right)
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }

        var out: [(String, Float, Float)] = []
        for obs in results {
            guard let best = obs.topCandidates(1).first else { continue }
            if let text = SignFilter.clean(best.string, confidence: best.confidence,
                                           relativeHeight: Double(obs.boundingBox.height)),
               !out.contains(where: { $0.0 == text }) {
                // Vision's box is in the upright (.right) image with a bottom-left origin;
                // rotate back to the camera's landscape image.
                let b = obs.boundingBox
                out.append((text, Float(1 - b.midY), Float(1 - b.midX)))
            }
        }
        return out
    }
}
