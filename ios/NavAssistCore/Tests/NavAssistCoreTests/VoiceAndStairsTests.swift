import Foundation
import Testing
@testable import NavAssistCore

// MARK: - Voice commands

@Test(arguments: [
    ("Save this place as kitchen", VoiceCommand.save("kitchen")),
    ("record location kitchen", .save("kitchen")),
    ("Record location as the front door", .save("front door")),
    ("remember this as my desk", .save("desk")),
    ("Mark here as bathroom.", .save("bathroom")),
    ("this is the living room", .save("living room")),
    ("Take me to the kitchen", .navigate("kitchen")),
    ("navigate me to room 204", .navigate("room 204")),
    ("Please navigate to the exit", .navigate("exit")),
    ("how do I get to the lift", .navigate("lift")),
    ("go to bathroom", .navigate("bathroom")),
    ("Where is the exit?", .whereIs("exit")),
    ("where's my bed", .whereIs("bed")),
    ("Where am I?", .whereAmI),
    ("what's around me", .whatsAround),
    ("Stop", .stop),
    ("cancel route", .stop),
    ("repeat", .repeatLast),
    ("what places do you know", .listPlaces),
    ("help", .help),
])
func parsesCommands(_ spoken: String, _ expected: VoiceCommand) {
    #expect(VoiceCommand.parse(spoken) == expected)
}

@Test func unknownSpeechIsReportedAsUnknown() {
    #expect(VoiceCommand.parse("banana") == .unknown("banana"))
    #expect(VoiceCommand.parse("") == .unknown(""))
}

// MARK: - Matching spoken names to places

@Test func normalizesSpokenNumbers() {
    #expect(PlaceMatcher.normalize("Room two oh four") == "room 204")
    #expect(PlaceMatcher.normalize("ROOM 2 0 4") == "room 204")
    #expect(PlaceMatcher.normalize("the way to the kitchen") == "way kitchen")   // "to" is not a number here
    #expect(PlaceMatcher.normalize("Floor 2") == "floor 2")
}

@Test func matchesDespiteRecognitionSlips() {
    #expect(PlaceMatcher.score("kitchen", "Kitchen") == 1)
    #expect(PlaceMatcher.score("room two oh four", "ROOM 204") == 1)
    #expect(PlaceMatcher.score("rest room", "Restroom") > 0.9)
    #expect(PlaceMatcher.score("kitchin", "Kitchen") > 0.8)
    #expect(PlaceMatcher.score("room 205", "Room 204") == 0, "different room numbers must not match")
    #expect(PlaceMatcher.score("garage", "Kitchen") < 0.5)
}

@Test func bestDestinationPrefersNamedPlacesThenNearestSign() {
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 20)])
    rec.markSign("EXIT", at: Vec2(0, 1))
    rec.markSign("EXIT", at: Vec2(0, 19))
    rec.markLandmark("Kitchen", at: Vec2(0, 10))
    rec.markSign("Kitchen", at: Vec2(0, 15))
    let g = rec.graph
    #expect(PlaceMatcher.best("exit", in: g, near: Vec2(0, 18))?.position.distance(to: Vec2(0, 19)) ?? 99 < 0.5)
    #expect(PlaceMatcher.best("exit", in: g, near: Vec2(0, 2))?.position.distance(to: Vec2(0, 1)) ?? 99 < 0.5)
    #expect(PlaceMatcher.best("kitchen", in: g, near: Vec2(0, 15))?.landmark == "Kitchen")
    #expect(PlaceMatcher.best("garage", in: g) == nil)
}

// MARK: - Signs

@Test func signFilterKeepsSignsAndDropsNoise() {
    #expect(SignFilter.clean("ROOM 204", confidence: 0.9, relativeHeight: 0.05) == "Room 204")
    #expect(SignFilter.clean("Exit", confidence: 0.9, relativeHeight: 0.05) == "Exit")
    #expect(SignFilter.clean("EXIT", confidence: 0.9, relativeHeight: 0.05) == "Exit", "so it isn't spelled E-X-I-T")
    #expect(SignFilter.clean("Exit", confidence: 0.3, relativeHeight: 0.05) == nil, "low confidence")
    #expect(SignFilter.clean("Exit", confidence: 0.9, relativeHeight: 0.01) == nil, "tiny text is not a sign")
    #expect(SignFilter.clean("This is a long sentence from a poster on the wall", confidence: 0.9, relativeHeight: 0.05) == nil)
    #expect(SignFilter.clean("www.example.com", confidence: 0.9, relativeHeight: 0.05) == nil)
    #expect(SignFilter.clean("#@!", confidence: 0.9, relativeHeight: 0.05) == nil)
}

@Test func theSameSignIsRememberedOnce() {
    var rec = TrailRecorder()
    walk(&rec, along: [Vec2(0, 0), Vec2(0, 10)])
    #expect(rec.markSign("Room 204", at: Vec2(0, 5)) != nil)
    #expect(rec.markSign("ROOM 204", at: Vec2(0, 6)) == nil, "seen again 1 m away")
    #expect(rec.markSign("Room 204", at: Vec2(0, 10)) != nil, "5 m away counts as another sign")
    #expect(rec.graph.nodes.filter { $0.signText != nil }.count == 2)
}

// MARK: - Floors and stairs

/// Walk along `corners`, where each corner also has a height.
func walk3D(_ rec: inout TrailRecorder, _ corners: [(Vec2, Double)], step: Double = 0.1) {
    for (a, b) in zip(corners, corners.dropFirst()) {
        let n = max(1, Int(max(a.0.distance(to: b.0), abs(b.1 - a.1)) / step))
        for i in 0...n {
            let f = Double(i) / Double(n)
            rec.add(a.0 + (b.0 - a.0) * f, height: a.1 + (b.1 - a.1) * f)
        }
    }
}

@Test func differentFloorsDoNotMerge() {
    var rec = TrailRecorder()
    walk3D(&rec, [(Vec2(0, 0), 0), (Vec2(0, 5), 0)])
    rec.breakTrail()
    walk3D(&rec, [(Vec2(-2, 2.5), 3), (Vec2(2, 2.5), 3)])   // corridor directly above
    let lower = rec.graph.nearestNode(to: Vec2(0, 2.5), height: 0)!
    let upper = rec.graph.nearestNode(to: Vec2(0, 2.5), height: 3)!
    #expect(rec.graph.shortestPath(from: lower, to: upper) == nil)
}

@Test func findsAFlightOfStairs() {
    // 3 m flat, then 12 steps up (2.0 m rise over 3 m), then 3 m flat.
    var rec = TrailRecorder()
    walk3D(&rec, [(Vec2(0, 0), 0), (Vec2(0, 3), 0), (Vec2(0, 6), 2.0), (Vec2(0, 9), 2.0)])
    let dest = rec.markLandmark("Upstairs", at: Vec2(0, 9), height: 2.0)
    let path = rec.graph.shortestPath(from: 0, to: dest)!
    let flights = findStairs(route: rec.graph.positions(of: path), heights: rec.graph.heights(of: path))
    #expect(flights.count == 1)
    #expect(flights[0].goingUp)
    #expect(abs(flights[0].steps - 12) <= 1)
    #expect(flights[0].start.distance(to: Vec2(0, 3)) < 0.6)
}

@Test func rampsAndDriftAreNotStairs() {
    let route = (0...20).map { Vec2(0, Double($0) * 0.5) }
    let ramp = (0...20).map { Optional(Double($0) * 0.5 * 0.08) }          // 8% wheelchair ramp
    #expect(findStairs(route: route, heights: ramp).isEmpty)
    let drift = (0...20).map { Optional(Double($0) * 0.01) }                // ARKit slowly drifting
    #expect(findStairs(route: route, heights: drift).isEmpty)
}

@Test func guideWarnsBeforeStairs() {
    var rec = TrailRecorder()
    walk3D(&rec, [(Vec2(0, 0), 0), (Vec2(0, 6), 0), (Vec2(0, 9), -2.0), (Vec2(0, 12), -2.0)])
    let dest = rec.markLandmark("Basement", at: Vec2(0, 12), height: -2.0)
    let path = rec.graph.shortestPath(from: 0, to: dest)!
    var guide = Guide(route: rec.graph.positions(of: path), heights: rec.graph.heights(of: path), destinationName: "Basement")
    let result = simulate(&guide, from: Vec2(0, 0))
    #expect(result.arrived)
    let warning = result.said.first { $0.hasPrefix("Stairs going down") }
    #expect(warning != nil, "said: \(result.said)")
    #expect(warning?.contains("Hold the handrail") == true)
    #expect(result.said.contains("Stairs now, going down."))
    #expect(result.said.contains("End of stairs."))
    // The warning comes before the stairs, not after.
    #expect(result.said.firstIndex { $0.hasPrefix("Stairs going down") }! < result.said.firstIndex(of: "Stairs now, going down.")!)
}

@Test func oldSavedPlacesStillLoad() throws {
    // A place saved by the first version of the app (no heights, no signs).
    let json = """
    {"version":1,"name":"Home","created":"2026-10-11T19:00:00Z",
     "graph":{"nodes":[{"id":0,"position":{"x":0,"y":0},"landmark":"Door"}],"neighbours":{"0":[]}}}
    """
    let place = try PlaceFile.decode(Data(json.utf8))
    #expect(place.graph.nodes[0].landmark == "Door")
    #expect(place.graph.nodes[0].height == nil)
}
