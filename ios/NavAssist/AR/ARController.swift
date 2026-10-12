import ARKit
import NavAssistCore
import Observation

/// Owns the ARKit session: where the phone is, which way the user faces, and whether
/// tracking can be trusted. ARKit's visual-inertial tracking is what replaces the
/// dataset's ground-truth poses from the Python prototype.
@Observable
final class ARController: NSObject, ARSessionDelegate {
    enum Tracking: Equatable {
        case stopped
        case starting
        /// Loaded a saved place and is still looking for familiar surroundings.
        case relocalizing
        case limited(String)
        case normal

        var isNormal: Bool { self == .normal }

        var spoken: String {
            switch self {
            case .stopped: return "Camera is off."
            case .starting: return "Starting. Hold the phone upright at chest height."
            case .relocalizing: return "Looking for a recognized spot. Slowly turn around with the phone held upright."
            case .limited(let why): return why
            case .normal: return "Tracking is good."
            }
        }
    }

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    let session = ARSession()

    // Shown on screen; updated 10 times a second rather than at the camera's 60.
    private(set) var tracking: Tracking = .stopped
    private(set) var mapping: ARFrame.WorldMappingStatus = .notAvailable
    private(set) var position: Vec2 = .zero
    private(set) var heading = Vec2(0, 1)
    /// Height of the phone in the map, in meters. Used to notice stairs.
    private(set) var height: Double = 0

    /// Called about 10 times a second while tracking is normal: position, heading, height, time.
    @ObservationIgnored var onPose: ((Vec2, Vec2, Double, TimeInterval) -> Void)?
    @ObservationIgnored var onTrackingChange: ((Tracking) -> Void)?
    @ObservationIgnored var obstacleSource: ObstacleSource?
    @ObservationIgnored var signReader: SignReader?

    @ObservationIgnored private var startedWithMap = false
    @ObservationIgnored private var floorY: Float?
    @ObservationIgnored private var lastPose: TimeInterval = 0

    func start(worldMap: ARWorldMap? = nil) {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]   // vertical: walls and doors
        config.worldAlignment = .gravity
        if Self.hasLiDAR { config.frameSemantics.insert(.sceneDepth) }
        config.initialWorldMap = worldMap
        startedWithMap = worldMap != nil
        floorY = nil
        session.delegate = self
        setTracking(startedWithMap ? .relocalizing : .starting)
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        onPose = nil
        onTrackingChange = nil
        obstacleSource = nil
        signReader = nil
        setTracking(.stopped)
    }

    func currentWorldMap() async throws -> ARWorldMap {
        try await withCheckedThrowingContinuation { cont in
            session.getCurrentWorldMap { map, error in
                if let map {
                    cont.resume(returning: map)
                } else {
                    cont.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                }
            }
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.camera.transform
        let h = Self.heading(of: t) ?? heading
        if frame.timestamp - lastPose >= 0.1 {
            lastPose = frame.timestamp
            mapping = frame.worldMappingStatus
            position = Vec2(fromWorldX: t.columns.3.x, z: t.columns.3.z)
            heading = h
            height = Double(t.columns.3.y)
            if tracking.isNormal {
                floorY = Self.floor(under: t, in: frame)
                onPose?(position, heading, height, frame.timestamp)
            }
        }
        // Obstacle warnings keep running while tracking is limited (a blank wall up close, a quick
        // turn, relocalising after a call): depth relative to the camera is still valid then, so
        // only the floor height falls back to an estimate.
        switch tracking {
        case .stopped, .starting:
            return
        case .normal:
            obstacleSource?.process(frame: frame, floorY: floorY ?? (t.columns.3.y - 1.35), heading: h)
            signReader?.process(frame: frame)
        case .limited, .relocalizing:
            obstacleSource?.process(frame: frame, floorY: t.columns.3.y - 1.35, heading: h)
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            startedWithMap = false        // relocalized (or never needed to)
            setTracking(.normal)
        case .notAvailable:
            setTracking(.limited("Tracking is not available."))
        case .limited(let reason):
            switch reason {
            case .relocalizing:
                setTracking(.relocalizing)
            case .initializing:
                setTracking(startedWithMap ? .relocalizing : .starting)
            case .excessiveMotion:
                setTracking(.limited("Moving too fast. Slow down."))
            case .insufficientFeatures:
                setTracking(.limited("Camera can't see enough detail. Point it at the room, not a blank wall, and check the lights are on."))
            @unknown default:
                setTracking(.limited("Tracking is limited."))
            }
        @unknown default:
            setTracking(.limited("Tracking is limited."))
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        setTracking(.limited("Camera interrupted."))
    }

    /// After an interruption (a call, the app in the background) ARKit would otherwise start
    /// over with a new origin, and positions would no longer line up with the saved routes.
    /// Relocalizing pauses guidance until the place is recognised again.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func session(_ session: ARSession, didFailWithError error: Error) {
        if (error as? ARError)?.code == .cameraUnauthorized {
            setTracking(.limited("NavAssist can't use the camera. Allow camera access in the Settings app, under NavAssist."))
        } else {
            setTracking(.limited("The camera stopped working: \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    private func setTracking(_ new: Tracking) {
        guard new != tracking else { return }
        tracking = new
        onTrackingChange?(new)
    }

    /// The floor under the user: a horizontal plane 0.9–2 m below the phone. Prefer one whose
    /// extent contains the phone's position, then one ARKit classified as floor, then the highest.
    /// (Taking the lowest plane anywhere used to pick the ground floor after going upstairs, and
    /// every obstacle on the upper floor was then filtered out as "above head height".)
    static func floor(under camera: simd_float4x4, in frame: ARFrame) -> Float? {
        let cam = camera.columns.3
        var best: (y: Float, score: Int)?
        for case let plane as ARPlaneAnchor in frame.anchors where plane.alignment == .horizontal {
            let y = plane.transform.columns.3.y
            let drop = cam.y - y
            guard drop >= 0.9, drop <= 2.0 else { continue }
            let local = plane.transform.inverse * SIMD4<Float>(cam.x, y, cam.z, 1)
            let ext = plane.planeExtent
            let under = abs(local.x - plane.center.x) <= ext.width / 2 + 0.3
                && abs(local.z - plane.center.z) <= ext.height / 2 + 0.3
            var isFloor = false
            if case .floor = plane.classification { isFloor = true }
            let score = (under ? 2 : 0) + (isFloor ? 1 : 0)
            if best == nil || score > best!.score || (score == best!.score && y > best!.y) { best = (y, score) }
        }
        return best?.y
    }

    /// Direction the user faces, on the floor plane. Normally the camera's view direction
    /// (out of the back of the phone); if the phone is tilted to point at the floor, the
    /// top edge of the phone is used instead.
    static func heading(of t: simd_float4x4) -> Vec2? {
        var f = Vec2(fromWorldX: -t.columns.2.x, z: -t.columns.2.z)
        if f.length < 0.5 {
            // In portrait, the top of the phone is the camera's -x axis.
            f = Vec2(fromWorldX: -t.columns.0.x, z: -t.columns.0.z)
        }
        return f.length > 0.1 ? f.normalized : nil
    }
}
