import Foundation
import Testing
@testable import NavAssistCore

// Regression tests for issues found in code review.

// MARK: - Speech priorities

@Test func safetyInterruptsNavigationButNotTheOtherWayRound() {
    var a = SpeechArbiter()
    #expect(a.request("Turn right now.", priority: .navigation, urgent: true, now: 0) == .speak("Turn right now."))
    #expect(a.request("Stop. Obstacle right in front.", priority: .safety, urgent: true, now: 0.3) == .interrupt("Stop. Obstacle right in front."))
    // A turn instruction can't cut the safety message off...
    #expect(a.request("Turn left now.", priority: .navigation, urgent: true, now: 0.5) == .none)
    // ...and once it finishes, the interrupted and waiting directions follow, newest-first within priority order.
    #expect(a.finished(now: 2.0) == .speak("Turn right now."))
}

@Test func aSafetyMessageIsNotCutOffInItsFirstMoments() {
    var a = SpeechArbiter()
    _ = a.request("Stop. Obstacle right in front.", priority: .safety, urgent: true, now: 0)
    #expect(a.request("Careful. Steps going up.", priority: .safety, urgent: true, now: 0.5) == .none)
    #expect(a.finished(now: 1.6) == .speak("Careful. Steps going up."))
}

@Test func oneShotDirectionsAreNotLostBehindInfo() {
    var a = SpeechArbiter()
    _ = a.request("Sign: Exit", priority: .info, urgent: false, now: 0)
    // A direction outranks a sign: it cuts in right away instead of waiting...
    #expect(a.request("In 2 meters, turn left.", priority: .navigation, urgent: false, now: 0.2) == .interrupt("In 2 meters, turn left."))
    _ = a.request("Sign: Room 204", priority: .info, urgent: false, now: 0.3)
    // ...and the interrupted sign comes back afterwards, then the next one.
    #expect(a.finished(now: 1) == .speak("Sign: Exit"))
    #expect(a.finished(now: 2) == .speak("Sign: Room 204"))
    // Two directions in a row: the second waits rather than being dropped.
    var b = SpeechArbiter()
    _ = b.request("Walk straight ahead, 6 meters.", priority: .navigation, urgent: false, now: 0)
    #expect(b.request("In 2 meters, turn left.", priority: .navigation, urgent: false, now: 0.5) == .none)
    #expect(b.finished(now: 1.5) == .speak("In 2 meters, turn left."))
}

@Test func staleMessagesAreDropped() {
    var a = SpeechArbiter()
    _ = a.request("Long sentence", priority: .navigation, urgent: false, now: 0)
    _ = a.request("Walk 3 meters, then turn left.", priority: .navigation, urgent: false, now: 0.1)
    #expect(a.finished(now: 10) == .none)
}

@Test func nothingIsSpokenWhileTheUserIsTalking() {
    var a = SpeechArbiter()
    _ = a.setListening(true, now: 0)
    #expect(a.request("Turn to 3 o'clock", priority: .navigation, urgent: false, now: 0.5) == .none)
    #expect(a.request("Stairs now, going down.", priority: .safety, urgent: true, now: 1) == .none)
    #expect(a.setListening(false, now: 2) == .speak("Stairs now, going down."))
    #expect(a.finished(now: 3) == .speak("Turn to 3 o'clock"))
}

@Test func batchesWithStopOrObstacleVibrationAreSafety() {
    #expect([GuidanceEvent.haptic(.stop), .speak("Stairs now, going down.", urgent: true)].impliedPriority == .safety)
    #expect([GuidanceEvent.haptic(.turnRight), .speak("Turn right now.", urgent: true)].impliedPriority == .navigation)
}

// MARK: - Floors

@Test func aDestinationDirectlyAboveIsNotArrivedOnTheWrongFloor() {
    // Kitchen at (0,0) ground floor; bedroom directly above at height 3 m, reached by stairs.
    let route = [Vec2(0, 0), Vec2(0, 4), Vec2(0, 8), Vec2(0.2, 0.2)]
    var g = Guide(route: route, heights: [0, 0, 3, 3], destinationName: "Bedroom")
    _ = g.start(position: .zero, heading: Vec2(0, 1), time: 0)
    let ev = g.update(position: Vec2(0.1, 0.1), heading: Vec2(0, 1), time: 0.1, height: 0)
    #expect(!ev.contains(.arrived))
    #expect(!g.finished)
    // Upstairs at the same x/y: now it's arrived.
    let up = g.update(position: Vec2(0.1, 0.1), heading: Vec2(0, 1), time: 30, height: 3)
    #expect(up.contains(.arrived) || g.target > 1)
}

@Test func pauseForgetsTheOffRouteTimer() {
    var g = Guide(route: [Vec2(0, 0), Vec2(0, 10)], destinationName: "Door")
    _ = g.start(position: .zero, heading: Vec2(0, 1), time: 0)
    _ = g.update(position: Vec2(3, 2), heading: Vec2(0, 1), time: 1)    // off route starts
    g.pause()                                                             // tracking lost for a while
    let ev = g.update(position: Vec2(3, 2), heading: Vec2(0, 1), time: 9)
    #expect(!ev.contains(.offRoute), "the first pose after a gap must not count as 8 s off route")
}

// MARK: - Routing from where the user is

@Test func aStrayFragmentDoesNotBlockTheRoute() {
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 10)])
    let goal = rec.markLandmark("Door", at: Vec2(0, 10))
    rec.breakTrail()
    walk(&rec, along: [Vec2(1.2, 5), Vec2(1.25, 5.3)])                // tracking-glitch fragment
    let here = Vec2(1.0, 5)
    #expect(rec.graph.shortestPath(from: rec.graph.nearestNode(to: here)!, to: goal) == nil, "nearest node is the fragment")
    #expect(rec.graph.route(from: here, to: goal) != nil, "but a connected node 1 m further works")
}

@Test func theRecentWindowStaysSmallSoLoopsStillClose() {
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 6)])
    for i in 0..<40 { rec.markSign("Sign \(i)", at: Vec2(Double(i) * 0.01 + 5, 6), dedupeRadius: 0) }
    // Walk a loop back to the start: it must join the first node again.
    walk(&rec, along: [Vec2(0, 6), Vec2(3, 6), Vec2(3, 0), Vec2(0, 0)])
    let start = rec.graph.nearestNode(to: Vec2(0, 0))!
    #expect(rec.graph.neighbours[start, default: []].count >= 2, "the loop should close at the start")
}

@Test func signsSeenFromAfarAttachToTheirPlaceOnTheMapOnly() {
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 12)])
    let before = rec.graph.nodes.count
    // Read from (0,0), but the sign is 10 m down the corridor, next to the path.
    let id = rec.markSign("EXIT", at: Vec2(0.4, 10), attachWithin: 2)
    #expect(id != nil)
    #expect(rec.graph.node(id!).position.distance(to: Vec2(0, 10)) < 0.6)
    #expect(rec.graph.nodes.count == before, "no new path invented")
    // A sign on a wall nobody has walked past isn't attached at all.
    #expect(rec.markSign("Lab", at: Vec2(8, 5), attachWithin: 2) == nil)
}

// MARK: - Relative-depth fallback

@Test func theFallbackDoesNotLockIntoStop() {
    let w = 30, h = 30
    var a = RelativeDepthZoneAnalyzer()
    _ = a.analyze(depth: [Float](repeating: 0.2, count: w * h), width: w, height: h)   // odd first frame
    var stops = 0
    for _ in 0..<300 {
        if a.analyze(depth: [Float](repeating: 0.5, count: w * h), width: w, height: h).immediateStop { stops += 1 }
    }
    #expect(stops <= 12, "re-seeds after a short while instead of saying stop forever (got \(stops))")
}

@Test func aStaleRulerIsDropped() {
    let w = 30, h = 30
    var a = RelativeDepthZoneAnalyzer()
    _ = a.analyze(depth: [Float](repeating: 0.2, count: w * h), width: w, height: h, time: 0)
    let r = a.analyze(depth: [Float](repeating: 0.5, count: w * h), width: w, height: h, time: 60)
    #expect(!r.immediateStop)
}

// MARK: - Voice

@Test func savingWithoutANameAsksForOne() {
    #expect(VoiceCommand.parse("save this place as") == .saveWithoutName)
    #expect(VoiceCommand.parse("save this place as here") == .saveWithoutName)
    #expect(VoiceCommand.parse("record location") == .saveWithoutName)
    #expect(VoiceCommand.parse("save this place as kitchen") == .save("kitchen"))
}

@Test func stopIsUnderstoodHoweverItIsSaid() {
    for s in ["stop", "Stop stop", "stop guiding", "stop the route", "cancel navigation", "cancel it"] {
        #expect(VoiceCommand.parse(s) == .stop, "\(s)")
    }
    #expect(VoiceCommand.parse("stop at the kitchen on the way") != .stop)
}

@Test func partOfANameIsEnough() {
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 10)])
    rec.markSign("Emergency Exit", at: Vec2(0, 9))
    #expect(PlaceMatcher.best("exit", in: rec.graph)?.signText == "Emergency Exit")
    #expect(PlaceMatcher.score("room 205", "Room 204") == 0, "numbers still have to match")
}

// MARK: - Trip logs and saved files

@Test func replanningStartsAFreshRouteInTheLog() {
    var rec = TripRecorder(participant: "P1, test", destination: "Door", adaptive: false, routeLength: 10)
    let g = Guide(route: [Vec2(0, 0), Vec2(0, 10)], destinationName: "Door")
    _ = rec.record(NavSample.make(guide: g, position: .zero, heading: Vec2(0, 1), height: 0, time: 0))
    rec.newRoute()
    _ = rec.record(NavSample.make(guide: g, position: Vec2(0, 1), heading: Vec2(0, 1), height: 0, time: 0.1))
    #expect(rec.log.samples.map(\.route) == [0, 1])
    let csv = rec.log.csv()
    #expect(csv.contains(",P1  test,"), "commas in names can't break the CSV columns")
}

@Test func corruptPlaceFilesAreRejectedNotCrashed() throws {
    let bad = """
    {"version":1,"name":"Home","created":"2026-10-11T19:00:00Z",
     "graph":{"nodes":[{"id":0,"position":{"x":0,"y":0}}],"neighbours":{"0":[5]}}}
    """
    #expect(throws: PlaceFile.ValidationError.self) { try PlaceFile.decode(Data(bad.utf8)) }
    let future = """
    {"version":99,"name":"Home","created":"2026-10-11T19:00:00Z","graph":{"nodes":[],"neighbours":{}}}
    """
    #expect(throws: PlaceFile.ValidationError.self) { try PlaceFile.decode(Data(future.utf8)) }
}
