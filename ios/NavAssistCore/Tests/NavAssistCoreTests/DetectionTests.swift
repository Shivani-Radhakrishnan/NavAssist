import Testing
@testable import NavAssistCore

private func box(_ kind: Detection.Kind, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Double = 0.9) -> Detection {
    Detection(kind: kind, confidence: c, x: x, y: y, width: w, height: h)
}

@Test func aDoorAheadGetsADistanceAndItsHandleSide() {
    let door = box(.door, 0.35, 0.1, 0.3, 0.8)          // centre x 0.5
    let handle = box(.doorHandle, 0.56, 0.5, 0.04, 0.04) // right of centre, inside the door
    let hints = DetectionInterpreter().hints(from: [door, handle]) { _, _ in 2.4 }
    #expect(hints.doorAhead == 2.4)
    #expect(hints.handleSide == .right)
}

@Test func doorsOutsideTheCorridorAndWeakDetectionsAreIgnored() {
    let side = box(.door, 0.0, 0.1, 0.2, 0.8)            // entirely left of the corridor
    let weak = box(.door, 0.4, 0.1, 0.2, 0.8, 0.2)
    let hints = DetectionInterpreter().hints(from: [side, weak]) { _, _ in 1.0 }
    #expect(hints.doorAhead == nil && hints.handleSide == nil)
}

@Test func theNearestDoorWinsAndAHandleOnAnotherDoorDoesNotCount() {
    let far = box(.door, 0.3, 0.2, 0.2, 0.5)
    let near = box(.door, 0.5, 0.1, 0.3, 0.8)
    let farHandle = box(.doorHandle, 0.32, 0.45, 0.03, 0.03)
    let hints = DetectionInterpreter().hints(from: [far, near, farHandle]) { u, _ in u < 0.45 ? 5.0 : 1.5 }
    #expect(hints.doorAhead == 1.5)
    #expect(hints.handleSide == nil)
}

@Test func stairsAheadAreMeasuredWhereTheyStart() {
    let stairs = box(.stairs, 0.2, 0.5, 0.6, 0.4)
    var sampledAt: Double = 0
    let hints = DetectionInterpreter().hints(from: [stairs]) { _, v in sampledAt = v; return 3.1 }
    #expect(hints.stairsInView && hints.stairsAhead == 3.1)
    #expect(sampledAt > 0.85)   // near the bottom edge of the box
}

@Test func withoutDepthStairsAreStillReported() {
    let hints = DetectionInterpreter().hints(from: [box(.stairs, 0.3, 0.4, 0.4, 0.5)]) { _, _ in nil }
    #expect(hints.stairsInView && hints.stairsAhead == nil)
}

@Test func announcementsUseTheHandleSideAndStairDistance() {
    var a = ObstacleAnnouncer()
    let stairs = ZoneReading(danger: [0, 0, 0], hints: SceneHints(stairsInView: true, stairsAhead: 3))
    let said = a.update(stairs, time: 0).compactMap { if case .speak(let s, _) = $0 { return s } else { return nil } }
    #expect(said.first?.hasPrefix("Stairs ahead, 3") == true)
}
