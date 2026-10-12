import ARKit
import NavAssistCore
import Observation
import UIKit

/// Everything the app does, on one screen:
/// - recognises a place it has mapped before, or starts a new map, as soon as it opens;
/// - maps continuously while the user walks, and saves automatically;
/// - reads signs and remembers where they are;
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
    @ObservationIgnored private var watchdogTimer: Timer?
    @ObservationIgnored private var lastSignSpoken = -Double.infinity
    @ObservationIgnored private var recentlySpokenSigns: [String: Double] = [:]
    @ObservationIgnored private var lastTrackingSpeech = -Double.infinity
    @ObservationIgnored private var started = false

    // Saving: the graph (small) is written whenever it changes; the ARKit world map (large) less
    // often. Generation counters make sure a save that finishes late can't mark newer changes
    // (say, a landmark saved a moment ago) as already saved.
    @ObservationIgnored private var changeGen = 0
    @ObservationIgnored private var savedGraphGen = 0
    @ObservationIgnored private var savedMapGen = 0
    @ObservationIgnored private var lastMapSave = -Double.infinity
    @ObservationIgnored private var savingGraph = false
    @ObservationIgnored private var savingMap = false
    @ObservationIgnored private var graphSaveAgain = false

    // Obstacle-warning watchdog.
    @ObservationIgnored private var lastReading = 0.0
    @ObservationIgnored private var warningsPausedSaid = false

    init(app: AppServices) {
        self.app = app
    }

    var graph: RouteGraph { recorder.graph }
    private var ar: ARController { app.ar }
    private var trackingOK: Bool { ar.tracking.isNormal }
    private var now: Double { CACurrentMediaTime() }

    // MARK: - Start up

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true

        ar.onPose = { [weak self] p, h, height, t in self?.pose(p, h, height, t) }
        ar.onTrackingChange = { [weak self] state in self?.trackingChanged(state) }
        signs.onSigns = { [weak self] sightings, t in self?.sawSigns(sightings, t) }
        ar.signReader = signs
        voice.onPartial = { [weak self] text in self?.heard = text }
        startObstacles()

        candidates = app.store.list().sorted { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }
        if candidates.isEmpty {
            startNewMap(firstLaunch: true)
        } else {
            tryNextPlace()
        }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.saveGraph()
            self?.saveMapIfDue()
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkWarnings() }

        voice.requestPermission { [weak self] ok in
            if !ok {
                self?.say("To use voice commands, allow the microphone and speech recognition for NavAssist in the Settings app.")
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
        load(p)
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
        load(PlaceFile(name: "Place \(n)", graph: RouteGraph()))
        mode = .mapping
        ar.start(worldMap: nil)
        if firstLaunch {
            say("Welcome. I'm mapping as you walk. Tap anywhere on the screen to give a command. "
                + "For example, say: save this place as kitchen. Later say: take me to kitchen.", urgent: true)
        } else {
            say("I don't recognize this place, so I'm starting a new map as you walk.", urgent: true)
        }
    }

    private func load(_ p: PlaceFile) {
        place = p
        recorder = TrailRecorder(graph: p.graph)
        placeName = p.name
        app.activePlaceName = p.name
        changeGen = 0
        savedGraphGen = 0
        savedMapGen = 0
        revision += 1
    }

    /// The app is going to the background: finish the trip log and save everything, with a
    /// little background time from iOS so the save isn't cut short.
    func enterBackground() {
        final class TaskBox { var id = UIBackgroundTaskIdentifier.invalid }
        let box = TaskBox()
        let finish = {
            guard box.id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        box.id = UIApplication.shared.beginBackgroundTask(withName: "Save NavAssist map") { finish() }
        endTrip(.abandoned)
        saveGraph()
        saveMap(force: true) { finish() }
    }

    // MARK: - Tracking

    private func trackingChanged(_ state: ARController.Tracking) {
        let t = now
        switch state {
        case .normal:
            if case .recognizing(let name) = mode {
                attemptTimer?.invalidate()
                candidates = []
                mode = .mapping
                place?.lastUsed = Date()
                markChanged()
                app.haptics.play(.onTrack)
                let known = graph.destinations.count
                say("This is \(name). I know \(known) \(known == 1 ? "place" : "places") here. Tap and say where you want to go.", urgent: true)
            } else if case .guiding = mode, t - lastTrackingSpeech < 60 {
                say("Tracking back.")
            }
        case .limited, .relocalizing:
            recorder.breakTrail()           // don't join the trail across a gap
            guide?.pause()                  // and don't count the gap as time spent off route
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
                    say(state.spoken)
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
                markChanged()
                revision += 1
            }
        default:
            return
        }
        guard case .guiding = mode, var g = guide else { return }
        let events = g.update(position: p, heading: h, time: t, height: height)
        guide = g
        app.handle(events)

        // Sensor signals -> predictor -> a cue if a hesitation or early turn looks likely.
        // Cues are the lowest priority, so they never talk over directions or warnings.
        if !g.finished, var tr = trip {
            let cues = tr.record(NavSample.make(guide: g, position: p, heading: h, height: height, time: t))
            trip = tr
            app.handle(cues, priority: .info)
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

    private func sawSigns(_ sightings: [SignReader.Sighting], _ t: TimeInterval) {
        guard trackingOK, mode == .mapping || isGuiding else { return }
        var announce: [String] = []
        for s in sightings {
            // Where is the sign? Cast the camera ray onto the walls ARKit has found.
            var signPos: Vec2?
            if let hit = raycast(s), simd_distance(hit, s.origin) < 12 {
                signPos = Vec2(fromWorldX: hit.x, z: hit.z)
            }
            // Store it on the walked path next to the sign (never inventing a new path); if the
            // sign is beside where the user stands, that spot works too.
            let at = signPos ?? ar.position
            if recorder.markSign(s.text, at: at, height: ar.height, attachWithin: signPos == nil ? 1.0 : 2.0) != nil {
                markChanged()
                revision += 1
            }
            if t - (recentlySpokenSigns[s.text] ?? -.infinity) > 60 {
                recentlySpokenSigns[s.text] = t
                announce.append(s.text)
            }
        }
        if !announce.isEmpty, t - lastSignSpoken > 4 {
            lastSignSpoken = t
            say("Sign: " + announce.prefix(3).joined(separator: ", "), priority: .info)
        }
    }

    private func raycast(_ s: SignReader.Sighting) -> simd_float3? {
        let query = ARRaycastQuery(origin: s.origin, direction: s.direction, allowing: .estimatedPlane, alignment: .any)
        guard let hit = ar.session.raycast(query).first else { return nil }
        let c = hit.worldTransform.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    // MARK: - Voice

    /// The whole screen is one button: tap to speak a command, tap again to stop early.
    func tap() {
        if voice.isListening {
            voice.finish()
            return
        }
        heard = ""
        listening = true
        app.speaker.setListening(true)        // speech waits; the microphone mustn't hear it
        voice.listen { [weak self] result in
            guard let self else { return }
            self.listening = false
            self.app.speaker.setListening(false)
            switch result {
            case .success(let text): self.handle(text)
            case .failure(.notAllowed):
                self.say("I need permission to use the microphone and speech recognition. "
                         + "Open the Settings app, find NavAssist, and allow both.", urgent: true)
            case .failure(.unavailable):
                self.say("Speech recognition isn't working right now. Tap and try again in a moment.", urgent: true)
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
        case .saveWithoutName:
            say("What should I call this place? Tap and say, for example: save this place as kitchen.", urgent: true)
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
        let key = PlaceMatcher.normalize(name)
        let existed = graph.landmarks.contains { PlaceMatcher.normalize($0.landmark ?? "") == key }
        recorder.markLandmark(name, at: ar.position, height: ar.height)
        markChanged()
        revision += 1
        app.haptics.play(.waypoint)
        say(existed ? "Moved \(name) here." : "Saved \(name).", urgent: true)
        saveGraph()
        saveMap(force: true)
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
        guard graph.nearestNode(to: here, height: ar.height, within: 3) != nil else {
            abandonRoute("You're more than 3 meters from anywhere I've mapped. Walk back toward where you've been.")
            return
        }
        // Start from a node that actually connects (preferring the one just walked from).
        guard let path = graph.route(from: here, height: ar.height, to: dest.id, preferred: recorder.lastNode) else {
            abandonRoute("I haven't mapped a way from here to \(name) yet. Once you've walked there with the app open, I can guide you.")
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
        if announceStart || trip == nil {
            endTrip(.abandoned)
            var tr = TripRecorder(participant: app.settings.participant, destination: name,
                                  adaptive: app.settings.adaptiveForNextTrip(),
                                  routeLength: g.remainingDistance(from: here), predictor: predictor)
            tr.coach.phrasing = app.settings.phrasing
            trip = tr
        } else {
            trip?.newRoute()               // same trip, new route after going off route
        }
        let events = g.start(position: here, heading: ar.heading, time: now)
        guide = g
        mode = .guiding(name)
        app.handle(announceStart ? events : events.filter {
            if case .speak(let s, _) = $0 { return !s.hasPrefix("Route to") } else { return true }
        })
    }

    private func abandonRoute(_ message: String) {
        guide = nil
        mode = .mapping
        endTrip(.abandoned)
        say(message, urgent: true)
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
        trip?.note(.stopped, at: now)
        endTrip(.stopped)
        guide = nil
        mode = .mapping
        app.speaker.stop()
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
        if log.samples.count >= 10 {
            app.trips.save(log)
            app.settings.recordSavedTrip()
        }
    }

    private var isGuiding: Bool { if case .guiding = mode { return true } else { return false } }

    private func say(_ text: String, priority: SpeechPriority = .navigation, urgent: Bool = false) {
        app.speaker.say(text, priority: priority, urgent: urgent)
    }

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
        if let path = graph.route(from: here, height: ar.height, to: n.id, preferred: recorder.lastNode) {
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

    // MARK: - Obstacles

    private func startObstacles() {
        let warn = app.settings.warnDistance
        // Loading the ~50 MB depth model on the main thread would delay the welcome message.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (source, problem) = ObstacleSources.best(warnDistance: warn)
            DispatchQueue.main.async {
                guard let self else { return }
                source?.onReading = { [weak self] reading, t in self?.obstacleReading(reading, t) }
                self.ar.obstacleSource = source
                if let problem, self.app.settings.obstacleWarnings {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.say(problem) }
                }
            }
        }
    }

    private func obstacleReading(_ reading: ZoneReading, _ t: TimeInterval) {
        lastReading = now
        if warningsPausedSaid {
            warningsPausedSaid = false
            say("Obstacle warnings are back.")
        }
        guard app.settings.obstacleWarnings else { return }
        announcer.phrasing = app.settings.phrasing      // follow Settings changes live
        let events = announcer.update(reading, time: t)
        // Warnings that come with a stop/obstacle vibration (and anything urgent) are safety.
        let urgent = events.contains { if case .speak(_, let u) = $0 { return u } else { return false } }
        app.handle(events, priority: urgent ? .safety : events.impliedPriority)
    }

    /// If obstacle readings stop arriving (camera interrupted, the model failed), say so once
    /// instead of silently leaving the user without warnings.
    private func checkWarnings() {
        guard app.settings.obstacleWarnings, ar.obstacleSource != nil, lastReading > 0 else { return }
        switch ar.tracking {
        case .stopped, .starting: return
        default: break
        }
        if now - lastReading > 2.0, !warningsPausedSaid {
            warningsPausedSaid = true
            app.haptics.play(.offRoute)
            say("Obstacle warnings paused. Walk slowly.", priority: .safety, urgent: true)
        }
    }

    // MARK: - Saving

    private func markChanged() { changeGen += 1 }

    /// Worth keeping on disk: a new place isn't saved until it has a name, a sign, or about 20 m
    /// of walked path (otherwise every failed recognition left an empty "Place N" behind).
    private var worthSaving: Bool {
        !graph.destinations.isEmpty || graph.nodes.count >= 40 || (place.map(app.store.hasMap) ?? false)
    }

    /// Save routes, names and signs. Small and quick, so it runs whenever they change.
    func saveGraph() {
        guard var p = place, changeGen != savedGraphGen, worthSaving else { return }
        if savingGraph { graphSaveAgain = true; return }
        savingGraph = true
        let gen = changeGen
        p.graph = recorder.graph
        p.lastUsed = Date()
        let store = app.store
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = (try? store.saveGraph(p)) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.savingGraph = false
                if ok { self.savedGraphGen = max(self.savedGraphGen, gen) }
                if self.graphSaveAgain { self.graphSaveAgain = false; self.saveGraph() }
            }
        }
    }

    private func saveMapIfDue() {
        if now - lastMapSave > 120 { saveMap(force: false) }
    }

    /// Save the ARKit world map (several MB), archived off the main thread.
    func saveMap(force: Bool, completion: (() -> Void)? = nil) {
        guard let p = place, worthSaving, !savingMap, force || changeGen != savedMapGen else { completion?(); return }
        switch ar.mapping {
        case .extending, .mapped: break
        default: completion?(); return           // ARKit can't produce a usable map yet
        }
        savingMap = true
        let gen = changeGen
        let store = app.store
        ar.session.getCurrentWorldMap { [weak self] map, _ in
            DispatchQueue.global(qos: .utility).async {
                let ok = map.flatMap { try? PlaceStore.archive($0) }.map { (try? store.saveMap($0, for: p)) != nil } ?? false
                DispatchQueue.main.async {
                    guard let self else { completion?(); return }
                    self.savingMap = false
                    if ok {
                        self.savedMapGen = max(self.savedMapGen, gen)
                        self.lastMapSave = self.now
                    }
                    completion?()
                }
            }
        }
    }
}
