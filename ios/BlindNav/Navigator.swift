import ARKit
import BlindNavCore
import Observation
import UIKit

/// Everything the app does, on one screen:
/// - recognises a place it has mapped before, or starts a new map, as soon as it opens;
/// - maps continuously while the user walks, and saves automatically;
/// - reads signs and remembers where they were;
/// - answers voice commands: save a place, navigate, where am I, what's around...;
/// - warns about obstacles and stairs.
@Observable
final class Navigator {
    enum Mode: Equatable {
        case starting
        case recognizing(String)
        case mapping
        case guiding(String)
    }

    private(set) var mode: Mode = .starting
    private(set) var placeName = ""
    private(set) var listening = false
    /// Words recognised while listening, shown on screen.
    private(set) var heard = ""
    /// Bumped when the map changes, so the mini map redraws.
    private(set) var revision = 0
    private(set) var recorder = TrailRecorder()

    @ObservationIgnored private let app: AppServices
    @ObservationIgnored private let voice = VoiceListener()
    @ObservationIgnored private let signs = SignReader()
    @ObservationIgnored private var place: PlaceFile?
    @ObservationIgnored private var guide: Guide?
    /// Records the current trip's sensor signals and runs the hesitation / early-turn predictor.
    @ObservationIgnored private var trip: TripRecorder?
    @ObservationIgnored private let predictor = TripStore.loadPredictor()
    @ObservationIgnored private var announcer = ObstacleAnnouncer()
    @ObservationIgnored private var candidates: [PlaceFile] = []
    @ObservationIgnored private var attemptTimer: Timer?
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var lastSignSpoken = -Double.infinity
    @ObservationIgnored private var lastTrackingSpeech = -Double.infinity
    @ObservationIgnored private var started = false

    init(app: AppServices) {
        self.app = app
    }

    var graph: RouteGraph { recorder.graph }
    private var ar: ARController { app.ar }
    private var trackingOK: Bool { ar.tracking.isNormal }

    // MARK: - Start up

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true

        ar.onPose = { [weak self] p, h, height, t in self?.pose(p, h, height, t) }
        ar.onTrackingChange = { [weak self] state in self?.trackingChanged(state) }
        signs.onSigns = { [weak self] texts, t in self?.sawSigns(texts, t) }
        ar.signReader = signs
        voice.onPartial = { [weak self] text in self?.heard = text }
        startObstacles()

        candidates = app.store.list().sorted { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }
        if candidates.isEmpty {
            startNewMap(firstLaunch: true)
        } else {
            tryNextPlace()
        }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.saveNow() }

        voice.requestPermission { [weak self] ok in
            if !ok {
                self?.say("To use voice commands, allow the microphone and speech recognition for NavAssist in the Settings app.", urgent: false)
            }
        }
    }

    /// Try to recognise the next saved place. ARKit can only look for one map at a time,
    /// so each is tried for 25 seconds, most recently used first.
    private func tryNextPlace() {
        attemptTimer?.invalidate()
        guard !candidates.isEmpty else {
            startNewMap(firstLaunch: false)
            return
        }
        let p = candidates.removeFirst()
        guard let map = try? app.store.loadMap(for: p) else {
            tryNextPlace()
            return
        }
        place = p
        recorder = TrailRecorder(graph: p.graph)
        placeName = p.name
        revision += 1
        mode = .recognizing(p.name)
        ar.start(worldMap: map)
        say("Checking if this is \(p.name). Hold the phone up and slowly turn around.", urgent: true)
        attemptTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self, case .recognizing = self.mode else { return }
            self.tryNextPlace()
        }
    }

    private func startNewMap(firstLaunch: Bool) {
        attemptTimer?.invalidate()
        let taken = Set(app.store.list().map { PlaceFile.folderName(for: $0.name) })
        var n = 1
        while taken.contains(PlaceFile.folderName(for: "Place \(n)")) { n += 1 }
        let name = "Place \(n)"
        place = PlaceFile(name: name, graph: RouteGraph())
        recorder = TrailRecorder()
        placeName = name
        revision += 1
        mode = .mapping
        ar.start(worldMap: nil)
        if firstLaunch {
            say("Welcome. I'm mapping as you walk. Tap anywhere on the screen to give a command. "
                + "For example, say: save this place as kitchen. Later say: take me to kitchen.", urgent: true)
        } else {
            say("I don't recognize this place, so I'm starting a new map as you walk.", urgent: true)
        }
    }

    func stop() {
        endTrip(.abandoned)
        saveNow()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Tracking

    private func trackingChanged(_ state: ARController.Tracking) {
        let t = CACurrentMediaTime()
        switch state {
        case .normal:
            if case .recognizing(let name) = mode {
                attemptTimer?.invalidate()
                candidates = []
                mode = .mapping
                place?.lastUsed = Date()
                dirty = true
                app.haptics.play(.onTrack)
                let known = graph.destinations.count
                say("This is \(name). I know \(known) \(known == 1 ? "place" : "places") here. Tap and say where you want to go.", urgent: true)
            } else if case .guiding = mode, t - lastTrackingSpeech < 60 {
                say("Tracking back.", urgent: false)
            }
        case .limited, .relocalizing:
            recorder.breakTrail()           // don't join the trail across a gap
            switch mode {
            case .mapping, .guiding:
                if t - lastTrackingSpeech > 8 {
                    lastTrackingSpeech = t
                    app.haptics.play(.offRoute)
                    say("Lost tracking. Stand still and slowly look around. \(state.spoken)", urgent: true)
                }
            case .recognizing:
                if case .limited = state, t - lastTrackingSpeech > 8 {
                    lastTrackingSpeech = t
                    say(state.spoken, urgent: false)
                }
            case .starting:
                break
            }
        default:
            break
        }
    }

    private func pose(_ p: Vec2, _ h: Vec2, _ height: Double, _ t: TimeInterval) {
        switch mode {
        case .mapping, .guiding:
            if recorder.add(p, height: height) {
                dirty = true
                revision += 1
            }
        default:
            return
        }
        guard case .guiding = mode, var g = guide else { return }
        let events = g.update(position: p, heading: h, time: t)
        guide = g
        app.handle(events)

        // Sensor signals -> predictor -> a cue if a hesitation or early turn looks likely.
        // Route directions take priority: no cue on a tick where the guide is speaking.
        if !g.finished, var tr = trip {
            let cues = tr.record(NavSample.make(guide: g, position: p, heading: h, height: height, time: t))
            trip = tr
            let guideSpoke = events.contains { if case .speak = $0 { return true } else { return false } }
            if !guideSpoke, !listening { app.handle(cues) }
        }

        if events.contains(.arrived) {
            trip?.note(.arrived, at: t)
            endTrip(.arrived)
            guide = nil
            mode = .mapping
        } else if events.contains(.offRoute) {
            trip?.note(.offRoute, at: t)
            say("Off route. Recalculating.", urgent: true)
            if let dest = g.destinationNodeID.map(graph.node) { plan(to: dest, announceStart: false) }
        }
    }

    // MARK: - Signs

    private func sawSigns(_ texts: [String], _ t: TimeInterval) {
        guard trackingOK, mode == .mapping || isGuiding else { return }
        var new: [String] = []
        for text in texts where recorder.markSign(text, at: ar.position, height: ar.height) != nil {
            new.append(text)
        }
        guard !new.isEmpty else { return }
        dirty = true
        revision += 1
        if t - lastSignSpoken > 4, !listening {
            lastSignSpoken = t
            say("Sign: " + new.prefix(3).joined(separator: ", "), urgent: false)
        }
    }

    // MARK: - Voice

    /// The whole screen is one button: tap to speak a command, tap again to stop early.
    func tap() {
        if voice.isListening {
            voice.finish()
            return
        }
        app.speaker.stop()
        heard = ""
        listening = true
        voice.listen { [weak self] result in
            guard let self else { return }
            self.listening = false
            switch result {
            case .success(let text): self.handle(text)
            case .failure(.notAllowed):
                self.say("I need permission to use the microphone and speech recognition. "
                         + "Open the Settings app, find NavAssist, and allow both.", urgent: true)
            case .failure(.unavailable):
                self.say("Speech recognition isn't available right now. Check the internet connection and try again.", urgent: true)
            }
        }
    }

    func handle(_ text: String) {
        let spoken = text.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty else {
            say("I didn't hear anything. Tap and try again.", urgent: true)
            return
        }
        switch VoiceCommand.parse(spoken) {
        case .save(let name): save(name)
        case .navigate(let name): navigate(to: name)
        case .whereIs(let name): describe(name)
        case .whereAmI: whereAmI()
        case .whatsAround: whatsAround()
        case .stop: stopRoute()
        case .repeatLast: repeatLast()
        case .listPlaces: listPlaces()
        case .help: help()
        case .unknown:
            say("Sorry, I didn't understand \"\(spoken)\". Say help to hear what you can say.", urgent: true)
        }
    }

    private func save(_ raw: String) {
        guard trackingOK, mode == .mapping || isGuiding else {
            say("Wait a moment, I'm still finding my position. Slowly look around.", urgent: true)
            return
        }
        let name = raw.capitalized
        recorder.markLandmark(name, at: ar.position, height: ar.height)
        dirty = true
        revision += 1
        app.haptics.play(.waypoint)
        say("Saved \(name).", urgent: true)
        saveNow()
    }

    private func navigate(to query: String) {
        guard trackingOK, mode == .mapping || isGuiding else {
            say("Wait a moment, I'm still finding my position.", urgent: true)
            return
        }
        guard let node = PlaceMatcher.best(query, in: graph, near: ar.position) else {
            say("I don't know \(query) yet. \(knownPlacesSentence())", urgent: true)
            return
        }
        plan(to: node, announceStart: true)
    }

    private func plan(to dest: RouteGraph.Node, announceStart: Bool) {
        let here = ar.position
        let name = dest.spokenName ?? "there"
        guard let start = graph.nearestNode(to: here, height: ar.height, within: 3) else {
            guide = nil
            mode = .mapping
            endTrip(.abandoned)
            say("You're more than 3 meters from anywhere I've mapped. Walk back toward where you've been.", urgent: true)
            return
        }
        guard let path = graph.shortestPath(from: start, to: dest.id) else {
            guide = nil
            mode = .mapping
            endTrip(.abandoned)
            say("I haven't mapped a way from here to \(name) yet. Once you've walked there with the app open, I can guide you.", urgent: true)
            return
        }
        var route = graph.positions(of: path)
        var heights = graph.heights(of: path)
        if here.distance(to: route[0]) > 0.3 {
            route.insert(here, at: 0)
            heights.insert(ar.height, at: 0)
        }
        var g = Guide(route: route, heights: heights, destinationName: name, settings: app.settings.guidance)
        g.destinationNodeID = dest.id
        if announceStart || trip == nil {          // a re-plan after going off route stays the same trip
            endTrip(.abandoned)
            var tr = TripRecorder(participant: app.settings.participant, destination: name,
                                  adaptive: app.settings.nextTripIsAdaptive(),
                                  routeLength: g.remainingDistance(from: here), predictor: predictor)
            tr.coach.phrasing = app.settings.phrasing
            trip = tr
        }
        let events = g.start(position: here, heading: ar.heading, time: CACurrentMediaTime())
        guide = g
        mode = .guiding(name)
        app.handle(announceStart ? events : events.filter {
            if case .speak(let s, _) = $0 { return !s.hasPrefix("Route to") } else { return true }
        })
    }

    private func describe(_ query: String) {
        guard trackingOK else { say("I'm still finding my position.", urgent: true); return }
        guard let node = PlaceMatcher.best(query, in: graph, near: ar.position) else {
            say("I don't know \(query) yet. \(knownPlacesSentence())", urgent: true)
            return
        }
        say("\(node.spokenName ?? query) is \(directionPhrase(to: node)).", urgent: true)
    }

    private func whereAmI() {
        guard trackingOK else { say(ar.tracking.spoken, urgent: true); return }
        var parts: [String] = []
        if let near = nearby(within: 15).first {
            let d = near.position.distance(to: ar.position)
            parts.append(d < 1.5 ? "You are at \(near.spokenName ?? "")." : "Near \(near.spokenName ?? ""), \(directionPhrase(to: near)).")
        } else {
            parts.append("Nothing I know is close by.")
        }
        if let g = guide, isGuiding { parts.append(g.status(position: ar.position, heading: ar.heading)) }
        say(parts.joined(separator: " "), urgent: true)
    }

    private func whatsAround() {
        guard trackingOK else { say(ar.tracking.spoken, urgent: true); return }
        let near = nearby(within: 12).prefix(4)
        if near.isEmpty {
            say("I don't know anything within 12 meters. Signs I read and places you save will show up here.", urgent: true)
        } else {
            say(near.map { "\($0.spokenName ?? ""), \(directionPhrase(to: $0))" }.joined(separator: ". ") + ".", urgent: true)
        }
    }

    private func stopRoute() {
        guard isGuiding else { say("There's no route to stop.", urgent: true); return }
        trip?.note(.stopped, at: CACurrentMediaTime())
        endTrip(.stopped)
        guide = nil
        mode = .mapping
        say("Stopped.", urgent: true)
    }

    private func repeatLast() {
        if let g = guide, isGuiding {
            say(g.status(position: ar.position, heading: ar.heading), urgent: true)
        } else if !app.caption.isEmpty {
            say(app.caption, urgent: true)
        }
    }

    private func listPlaces() { say(knownPlacesSentence(), urgent: true) }

    private func help() {
        say("Tap anywhere, then speak. You can say: save this place as kitchen. Take me to kitchen. "
            + "Where is the exit. Where am I. What's around. Stop. Repeat. Or, what places do you know.", urgent: true)
    }

    // MARK: - Helpers

    /// Save the current trip's log (if any samples were recorded) and clear it.
    private func endTrip(_ outcome: TripLog.Outcome) {
        guard var tr = trip else { return }
        trip = nil
        let log = tr.finish(outcome)
        if log.samples.count >= 10 { app.trips.save(log) }
    }

    private var isGuiding: Bool { if case .guiding = mode { return true } else { return false } }

    private func say(_ text: String, urgent: Bool) { app.speaker.say(text, urgent: urgent) }

    private func nearby(within r: Double) -> [RouteGraph.Node] {
        let here = ar.position
        return graph.destinations
            .filter { $0.position.distance(to: here) <= r && sameFloorAsMe($0) }
            .sorted { $0.position.distance(to: here) < $1.position.distance(to: here) }
    }

    private func sameFloorAsMe(_ n: RouteGraph.Node) -> Bool {
        guard let h = n.height else { return true }
        return abs(h - ar.height) < 1.2
    }

    /// "8 meters away, at 2 o'clock" (walking distance when a route exists).
    private func directionPhrase(to n: RouteGraph.Node) -> String {
        let here = ar.position
        let straight = n.position.distance(to: here)
        if straight < 1 { return "right here" }
        let clock = clockDirection(signedAngle(from: ar.heading, to: n.position - here))
        var walking = straight
        if let s = graph.nearestNode(to: here, height: ar.height, within: 3), let path = graph.shortestPath(from: s, to: n.id) {
            let pts = graph.positions(of: path)
            walking = zip(pts, pts.dropFirst()).reduce(here.distance(to: pts[0])) { $0 + $1.0.distance(to: $1.1) }
        }
        var phrase = "\(app.settings.phrasing.distance(walking)) away, at \(clock) o'clock"
        if let h = n.height, h - ar.height > 1.2 { phrase += ", upstairs" }
        if let h = n.height, ar.height - h > 1.2 { phrase += ", downstairs" }
        return phrase
    }

    private func knownPlacesSentence() -> String {
        let named = graph.landmarks.compactMap(\.landmark)
        var seen = Set<String>()
        let signTexts = graph.nodes.compactMap(\.signText).filter { seen.insert(PlaceMatcher.normalize($0)).inserted }
        if named.isEmpty && signTexts.isEmpty {
            return "I don't know any places here yet. Say: save this place as, and then a name."
        }
        var parts: [String] = []
        if !named.isEmpty { parts.append("Places you saved: " + named.prefix(10).joined(separator: ", ") + ".") }
        if !signTexts.isEmpty { parts.append("Signs I've read: " + signTexts.prefix(8).joined(separator: ", ") + ".") }
        return parts.joined(separator: " ")
    }

    private func startObstacles() {
        let (source, problem) = ObstacleSources.best(warnDistance: app.settings.warnDistance)
        announcer.phrasing = app.settings.phrasing
        source?.onReading = { [weak self] reading, t in
            guard let self, self.app.settings.obstacleWarnings else { return }
            let events = self.announcer.update(reading, time: t)
            // Don't talk over the user while they're giving a command; vibrate instead.
            self.app.handle(self.listening ? events.filter { if case .haptic = $0 { return true } else { return false } } : events)
        }
        ar.obstacleSource = source
        if let problem, app.settings.obstacleWarnings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.say(problem, urgent: false) }
        }
    }

    /// Save the map and routes now (also runs every 30 seconds and when the app is closed).
    func saveNow() {
        guard var p = place, dirty, !saving, graph.nodes.count >= 2 else { return }
        switch ar.mapping {
        case .extending, .mapped: break
        default: return           // ARKit can't produce a usable map yet
        }
        saving = true
        p.graph = recorder.graph
        p.lastUsed = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.saving = false }
            do {
                let map = try await self.ar.currentWorldMap()
                try self.app.store.save(p, map: map)
                self.place = p
                self.dirty = false
            } catch {
                // Try again on the next timer tick.
            }
        }
    }
}
