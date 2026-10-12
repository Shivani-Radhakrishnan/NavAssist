import ARKit
import BlindNavCore
import Observation
import UIKit

/// One trip: recognise the place, pick a destination, follow the route there.
@Observable
final class NavigationSession {
    enum Phase: Equatable {
        case loading
        case locating        // ARKit is relocalizing against the saved map
        case choosing        // located; waiting for a destination
        case guiding
        case arrived
        case failed(String)
    }

    let place: PlaceFile
    private(set) var phase: Phase = .loading
    private(set) var destination: RouteGraph.Node?
    private(set) var obstacleNote: String?
    var obstaclesOn: Bool {
        didSet { obstaclesOn ? startObstacles() : stopObstacles() }
    }

    private let app: AppServices
    private var guide: Guide?
    private var announcer = ObstacleAnnouncer()
    private var lastTrackingSpeech = -Double.infinity
    private var replans = 0

    init(place: PlaceFile, app: AppServices) {
        self.place = place
        self.app = app
        self.obstaclesOn = app.settings.obstacleWarnings
    }

    var landmarks: [RouteGraph.Node] { place.graph.landmarks }

    func begin() {
        UIApplication.shared.isIdleTimerDisabled = true
        let map: ARWorldMap
        do {
            map = try app.store.loadMap(for: place)
        } catch {
            fail("Could not open the saved map for \(place.name).")
            return
        }
        let ar = app.ar
        ar.onPose = { [weak self] p, h, t in self?.pose(p, h, t) }
        ar.onTrackingChange = { [weak self] state in self?.trackingChanged(state) }
        ar.start(worldMap: map)
        phase = .locating
        app.speaker.say("Opening \(place.name). Hold the phone upright at chest height, camera facing forward, "
                        + "and slowly turn around until I recognize where you are.", urgent: true)
        if obstaclesOn { startObstacles() }
    }

    func end() {
        UIApplication.shared.isIdleTimerDisabled = false
        app.speaker.stop()
        app.ar.stop()
    }

    func go(to node: RouteGraph.Node) {
        destination = node
        replans = 0
        plan(announceStart: true)
    }

    func cancelRoute() {
        guide = nil
        destination = nil
        phase = .choosing
        app.speaker.say("Route cancelled. Choose a destination.", urgent: true)
    }

    func repeatInstruction() {
        switch phase {
        case .guiding:
            if let g = guide { app.speaker.say(g.status(position: app.ar.position, heading: app.ar.heading), urgent: true) }
        case .locating:
            app.speaker.say(app.ar.tracking.spoken, urgent: true)
        case .choosing, .arrived:
            app.speaker.say(nearbySummary(), urgent: true)
        case .loading, .failed:
            break
        }
    }

    // MARK: - Private

    private func plan(announceStart: Bool) {
        guard let dest = destination else { return }
        let here = app.ar.position
        guard let startNode = place.graph.nearestNode(to: here, within: 3.0) else {
            phase = .choosing
            app.speaker.say("You are more than 3 meters from any recorded path. Go back toward a place you know, "
                            + "or ask the person who recorded this place to add a route from here.", urgent: true)
            return
        }
        guard let path = place.graph.shortestPath(from: startNode, to: dest.id) else {
            phase = .choosing
            app.speaker.say("There is no recorded route from here to \(dest.landmark ?? "there").", urgent: true)
            return
        }
        // First leg goes from where the user actually stands to the recorded path.
        var route = place.graph.positions(of: path)
        if here.distance(to: route[0]) > 0.3 { route.insert(here, at: 0) }
        var g = Guide(route: route, destinationName: dest.landmark ?? "your destination", settings: app.settings.guidance)
        phase = .guiding
        let t = CACurrentMediaTime()
        let events = g.start(position: here, heading: app.ar.heading, time: t)
        guide = g
        app.handle(announceStart ? events : events.filter { if case .speak(let s, _) = $0 { return !s.hasPrefix("Route to") } else { return true } })
    }

    private func pose(_ p: Vec2, _ h: Vec2, _ t: TimeInterval) {
        switch phase {
        case .locating:
            phase = .choosing
            app.haptics.play(.onTrack)
            app.speaker.say("Location found. \(nearbySummary()) Choose a destination.", urgent: true)
        case .guiding:
            guard var g = guide else { return }
            let events = g.update(position: p, heading: h, time: t)
            guide = g
            app.handle(events)
            if events.contains(.arrived) {
                phase = .arrived
                guide = nil
            } else if events.contains(.offRoute) {
                replans += 1
                app.speaker.say("Off route. Recalculating.", urgent: true)
                plan(announceStart: false)
            }
        default:
            break
        }
    }

    private func trackingChanged(_ state: ARController.Tracking) {
        let t = CACurrentMediaTime()
        switch state {
        case .limited where phase == .locating:
            // e.g. camera permission denied: say so instead of waiting silently forever.
            if t - lastTrackingSpeech > 5 {
                lastTrackingSpeech = t
                app.speaker.say(state.spoken, urgent: true)
            }
        case .limited, .relocalizing:
            // Guidance is paused automatically (no poses arrive); tell the user why, but not too often.
            if phase == .guiding || phase == .choosing, t - lastTrackingSpeech > 5 {
                lastTrackingSpeech = t
                app.haptics.play(.offRoute)
                app.speaker.say("Lost tracking. Stand still, hold the phone upright and slowly look around. \(state.spoken)", urgent: true)
            }
        case .normal:
            if phase == .guiding, t - lastTrackingSpeech < 60 {
                app.speaker.say("Tracking back.", urgent: false)
            }
        default:
            break
        }
    }

    private func nearbySummary() -> String {
        let here = app.ar.position
        guard let n = place.graph.landmarks.min(by: { $0.position.distance(to: here) < $1.position.distance(to: here) }),
              let name = n.landmark else { return "" }
        let d = n.position.distance(to: here)
        if d < 1.5 { return "You are at \(name)." }
        return "Nearest landmark: \(name), \(app.settings.phrasing.distance(d)) away."
    }

    private func startObstacles() {
        let (source, problem) = ObstacleSources.best(warnDistance: app.settings.warnDistance)
        obstacleNote = problem
        guard let source else { return }
        announcer.reset()
        announcer.phrasing = app.settings.phrasing
        source.onReading = { [weak self] reading, t in
            guard let self, self.obstaclesOn else { return }
            self.app.handle(self.announcer.update(reading, time: t))
        }
        app.ar.obstacleSource = source
    }

    private func stopObstacles() {
        app.ar.obstacleSource = nil
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        app.speaker.say(message, urgent: true)
    }
}
