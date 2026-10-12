import ARKit
import BlindNavCore
import Observation
import UIKit

/// A sighted helper walks the routes once. Every step is recorded as a walkable path;
/// named landmarks become destinations. Can also extend a place recorded earlier.
@Observable
final class RecordSession {
    let name: String
    private(set) var recorder: TrailRecorder
    private(set) var paused = false
    private(set) var saving = false
    /// Bumped whenever the graph changes, so the map redraws.
    private(set) var revision = 0
    private(set) var walkedMeters = 0.0

    private let app: AppServices
    private let existingMap: ARWorldMap?
    private var lastPoint: Vec2?

    init(name: String, existing: PlaceFile? = nil, existingMap: ARWorldMap? = nil, app: AppServices) {
        self.name = existing?.name ?? name
        self.recorder = TrailRecorder(graph: existing?.graph ?? RouteGraph())
        self.existingMap = existingMap
        self.app = app
    }

    var isExtending: Bool { existingMap != nil }
    var graph: RouteGraph { recorder.graph }

    func begin() {
        UIApplication.shared.isIdleTimerDisabled = true
        app.ar.onPose = { [weak self] p, _, _ in self?.pose(p) }
        app.ar.onTrackingChange = nil
        app.ar.start(worldMap: existingMap)
    }

    func end() {
        UIApplication.shared.isIdleTimerDisabled = false
        app.ar.stop()
    }

    func togglePause() {
        paused.toggle()
        recorder.breakTrail()
        lastPoint = nil
        app.speaker.say(paused ? "Recording paused" : "Recording", urgent: true)
    }

    func addLandmark(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, app.ar.tracking.isNormal else { return }
        recorder.markLandmark(name, at: app.ar.position)
        revision += 1
        app.haptics.play(.waypoint)
        app.speaker.say("Saved \(name) here", urgent: true)
    }

    /// How good the saved map will be at recognising this place later.
    var mapQuality: (text: String, good: Bool) {
        switch app.ar.mapping {
        case .mapped: return ("Map quality: good. Safe to save.", true)
        case .extending: return ("Map quality: fair. Keep walking and look around.", false)
        case .limited: return ("Map quality: low. Look around slowly at walls and furniture.", false)
        default: return ("Map quality: none yet. Walk around slowly.", false)
        }
    }

    @MainActor
    func save() async throws {
        saving = true
        defer { saving = false }
        let map = try await app.ar.currentWorldMap()
        try app.store.save(PlaceFile(name: name, graph: recorder.graph), map: map)
        app.speaker.say("\(name) saved with \(recorder.graph.landmarks.count) landmarks.", urgent: true)
    }

    private func pose(_ p: Vec2) {
        guard !paused else { return }
        if let last = lastPoint { walkedMeters += last.distance(to: p) }
        lastPoint = p
        if recorder.add(p) { revision += 1 }
    }
}
