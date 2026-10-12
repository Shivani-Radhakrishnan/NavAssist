import Foundation
import Testing
@testable import BlindNavCore

// MARK: - Helpers

/// Walk a polyline in small steps, like a helper recording a route.
func walk(_ recorder: inout TrailRecorder, along corners: [Vec2], step: Double = 0.1, wobble: Double = 0) {
    var rng = SystemRandomNumberGenerator()
    for (a, b) in zip(corners, corners.dropFirst()) {
        let n = max(1, Int(a.distance(to: b) / step))
        for i in 0...n {
            let p = a + (b - a) * (Double(i) / Double(n))
            let jitter = wobble == 0 ? Vec2.zero
                : Vec2(Double.random(in: -wobble...wobble, using: &rng), Double.random(in: -wobble...wobble, using: &rng))
            recorder.add(p + jitter)
        }
    }
}

/// Simulate a blind user following the guide: walks toward the current target at
/// `speed` m/s, turning instantly. Returns all spoken text and whether they arrived.
func simulate(_ guide: inout Guide, from start: Vec2, speed: Double = 1.0, dt: Double = 0.1,
              maxSeconds: Double = 120) -> (said: [String], arrived: Bool, events: [GuidanceEvent]) {
    var p = start
    var heading = Vec2(0, 1)
    var events = guide.start(position: p, heading: heading, time: 0)
    var t = 0.0
    while t < maxSeconds && !guide.finished {
        t += dt
        let target = guide.route[guide.target]
        let dir = (target - p).normalized
        if dir.length > 0 { heading = dir }
        let step = min(speed * dt, p.distance(to: target))
        p = p + heading * step
        events += guide.update(position: p, heading: heading, time: t)
    }
    let said = events.compactMap { if case .speak(let s, _) = $0 { return s } else { return nil } }
    return (said, events.contains(.arrived), events)
}

// MARK: - Phrases

@Test func clockFaceDirections() {
    #expect(clockDirection(0) == 12)
    #expect(clockDirection(90) == 9)      // left
    #expect(clockDirection(-90) == 3)     // right
    #expect(clockDirection(180) == 6)
    #expect(clockDirection(-30) == 1)
    #expect(clockDirection(-60) == 2)
}

@Test func turnWordsByAngle() {
    #expect(turnWords(5) == "Continue straight")
    #expect(turnWords(90) == "Turn left")
    #expect(turnWords(-90) == "Turn right")
    #expect(turnWords(-30) == "Bear slightly right")
    #expect(turnWords(170) == "Turn around")
}

@Test func distancePhrasing() {
    #expect(Phrasing(unit: .meters).distance(1.1) == "1 meter")
    #expect(Phrasing(unit: .meters).distance(2.7) == "2.5 meters")
    #expect(Phrasing(unit: .meters).distance(12.4) == "12 meters")
    #expect(Phrasing(unit: .steps, stepLength: 0.7).distance(3.5) == "5 steps")
    #expect(Phrasing(unit: .feet).distance(1) == "3 feet")
}

@Test func signedAngleIsPositiveToTheLeft() {
    let forward = Vec2(0, 1)
    #expect(abs(signedAngle(from: forward, to: Vec2(-1, 0)) - 90) < 1e-9)
    #expect(abs(signedAngle(from: forward, to: Vec2(1, 0)) + 90) < 1e-9)
    // ARKit: camera looking along -z is "forward"; +x is right.
    #expect(Vec2(fromWorldX: 0, z: -1) == Vec2(0, 1))
    #expect(Vec2(fromWorldX: 1, z: 0) == Vec2(1, 0))
}

// MARK: - Recording and routing

@Test func recorderDropsNodesAtSpacing() {
    var rec = TrailRecorder(spacing: 0.5)
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 5)])
    #expect(rec.graph.nodes.count == 11)                 // 0, 0.5, ... 5.0
    #expect(rec.graph.shortestPath(from: 0, to: 10)?.count == 11)
}

@Test func separateWalksJoinAtJunctions() {
    // Helper walks a corridor north, then later walks a second corridor that crosses it.
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 8)])
    rec.markLandmark("North end", at: Vec2(0, 8))
    rec.breakTrail()
    walk(&rec, along: [Vec2(-4, 4), Vec2(4, 4)])
    rec.markLandmark("East room", at: Vec2(4, 4))

    let g = rec.graph
    let north = g.landmarks.first { $0.landmark == "North end" }!.id
    let east = g.landmarks.first { $0.landmark == "East room" }!.id
    let path = g.shortestPath(from: north, to: east)
    #expect(path != nil, "crossing walks should connect")
    // North end -> junction near (0,4) -> east: about 4 + 4 = 8 m, not a huge detour.
    let pts = g.positions(of: path!)
    let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    #expect(length < 9.5)
}

@Test func unconnectedPlacesHaveNoRoute() {
    var g = RouteGraph()
    let a = g.addNode(at: Vec2(0, 0))
    let b = g.addNode(at: Vec2(10, 0))
    #expect(g.shortestPath(from: a, to: b) == nil)
}

@Test func renamingALandmarkMovesIt() {
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 4)])
    rec.markLandmark("Desk", at: Vec2(0, 1))
    rec.markLandmark("Desk", at: Vec2(0, 4))
    let desks = rec.graph.nodes.filter { $0.landmark == "Desk" }
    #expect(desks.count == 1)
    #expect(desks[0].position.distance(to: Vec2(0, 4)) < 0.3)
}

@Test func placeFileRoundTrips() throws {
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(3, 0)])
    rec.markLandmark("Door", at: Vec2(3, 0))
    let file = PlaceFile(name: "Home", graph: rec.graph, created: Date(timeIntervalSince1970: 1_700_000_000))
    let back = try PlaceFile.decode(file.encoded())
    #expect(back == file)
    #expect(PlaceFile.folderName(for: "Mom's flat / 2nd") == "Mom_s flat _ 2nd")
}

// MARK: - Guidance

@Test func simplifyRemovesWobble() {
    var pts: [Vec2] = []
    for i in 0...20 { pts.append(Vec2(i % 2 == 0 ? 0.05 : -0.05, Double(i) * 0.5)) }
    #expect(simplifyRoute(pts, tolerance: 0.35).count == 2)
}

@Test func guidesAroundAnLShapedCorridor() {
    // 6 m north, then 4 m east (a right turn), recorded with 5 cm of ARKit wobble.
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 6), Vec2(4, 6)], wobble: 0.05)
    let dest = rec.markLandmark("Kitchen", at: Vec2(4, 6))
    let path = rec.graph.shortestPath(from: 0, to: dest)!
    var guide = Guide(route: rec.graph.positions(of: path), destinationName: "Kitchen")
    #expect(guide.route.count == 3, "wobble should be simplified to two legs")

    let result = simulate(&guide, from: Vec2(0, 0))
    #expect(result.arrived)
    #expect(result.said.first?.hasPrefix("Route to Kitchen") == true)
    #expect(result.said.contains { $0.contains("turn right") }, "should warn of the upcoming turn")
    #expect(result.said.contains { $0.hasPrefix("Turn right now") })
    #expect(result.said.last == "You have arrived at Kitchen.")
    #expect(!result.said.contains { $0.contains("o'clock") }, "a user who follows exactly needs no corrections")
}

@Test func correctsAUserFacingTheWrongWay() {
    var guide = Guide(route: [Vec2(0, 0), Vec2(0, 5)], destinationName: "Door")
    // Facing east (right) when the route goes north.
    let events = guide.start(position: Vec2(0, 0), heading: Vec2(1, 0), time: 0)
    #expect(events.contains(.speak("Turn to 9 o'clock, then walk 5 meters.", urgent: false)))
    #expect(events.contains(.haptic(.turnLeft)))
    // After turning to face north they hear a confirmation.
    let later = guide.update(position: Vec2(0, 0.1), heading: Vec2(0, 1), time: 1)
    #expect(later.contains(.speak("Straight ahead", urgent: false)))
}

@Test func headingCorrectionsAreRateLimited() {
    var guide = Guide(route: [Vec2(0, 0), Vec2(0, 10)], destinationName: "Door")
    _ = guide.start(position: .zero, heading: Vec2(0, 1), time: 0)
    var prompts = 0
    var t = 0.0
    while t < 10 {
        t += 0.1
        let ev = guide.update(position: Vec2(0, 0.5), heading: Vec2(1, 0), time: t)  // stubbornly facing right
        prompts += ev.filter { if case .speak(let s, _) = $0 { return s.contains("o'clock") } else { return false } }.count
    }
    #expect(prompts >= 2 && prompts <= 3, "about one prompt every 4 seconds, got \(prompts)")
}

@Test func detectsLeavingTheRoute() {
    var guide = Guide(route: [Vec2(0, 0), Vec2(0, 10)], destinationName: "Door")
    _ = guide.start(position: .zero, heading: Vec2(0, 1), time: 0)
    // Briefly 2 m off (under the 2.5 s limit): no re-route.
    for i in 1...10 { _ = guide.update(position: Vec2(2, 3), heading: Vec2(0, 1), time: Double(i) * 0.1) }
    _ = guide.update(position: Vec2(0, 3), heading: Vec2(0, 1), time: 1.2)
    #expect(!guide.finished)
    // Staying off for 3 s: off-route.
    var events: [GuidanceEvent] = []
    for i in 0...30 { events += guide.update(position: Vec2(2.5, 4), heading: Vec2(0, 1), time: 2 + Double(i) * 0.1) }
    #expect(events.contains(.offRoute))
    #expect(guide.finished)
}

@Test func walkingPastACornerStillAdvances() {
    var guide = Guide(route: [Vec2(0, 0), Vec2(0, 4), Vec2(4, 4)], destinationName: "Room")
    _ = guide.start(position: .zero, heading: Vec2(0, 1), time: 0)
    // Cut the corner diagonally without ever being within 0.9 m of (0, 4).
    _ = guide.update(position: Vec2(0, 2.8), heading: Vec2(0, 1), time: 1)
    _ = guide.update(position: Vec2(1.0, 3.9), heading: Vec2(1, 0), time: 2)
    #expect(guide.target == 2)
}

@Test func statusSummarisesTheRoute() {
    let guide = Guide(route: [Vec2(0, 0), Vec2(0, 3), Vec2(-2, 3)], destinationName: "Bathroom")
    let s = guide.status(position: .zero, heading: Vec2(0, 1))
    #expect(s == "Bathroom is 5 meters away. Walk 3 meters, then turn left.")
}

@Test func stepsUnitIsUsedEverywhere() {
    var settings = GuidanceSettings()
    settings.phrasing = Phrasing(unit: .steps, stepLength: 0.5)
    var guide = Guide(route: [Vec2(0, 0), Vec2(0, 3)], destinationName: "Sofa", settings: settings)
    let ev = guide.start(position: .zero, heading: Vec2(0, 1), time: 0)
    #expect(ev.first == .speak("Route to Sofa, 6 steps.", urgent: true))
}
