import Foundation
import Testing
@testable import NavAssistCore

/// A flat wall of points `distance` m ahead spanning lateral range `from...to`.
func wall(at distance: Double, from: Double, to: Double, height: ClosedRange<Double> = 0.2...1.8) -> [ObstaclePoint] {
    var pts: [ObstaclePoint] = []
    var x = from
    while x <= to {
        var h = height.lowerBound
        while h <= height.upperBound {
            pts.append(ObstaclePoint(lateral: x, forward: distance, height: h))
            h += 0.1
        }
        x += 0.05
    }
    return pts
}

func floorPoints() -> [ObstaclePoint] {
    var pts: [ObstaclePoint] = []
    for f in stride(from: 0.3, to: 4.0, by: 0.05) {
        for x in stride(from: -1.0, to: 1.0, by: 0.1) { pts.append(ObstaclePoint(lateral: x, forward: f, height: 0.01)) }
    }
    return pts
}

@Test func metricAnalyzerIgnoresTheFloor() {
    let r = MetricZoneAnalyzer().analyze(floorPoints())
    #expect(r.danger == [0, 0, 0])
    #expect(!r.immediateStop)
}

@Test func metricAnalyzerFindsZonesAndDistances() {
    let a = MetricZoneAnalyzer()
    let r = a.analyze(floorPoints() + wall(at: 1.0, from: -0.2, to: 0.2) + wall(at: 3.0, from: 0.5, to: 1.0))
    #expect(r.danger[Zone.center.rawValue] >= 1.0)
    #expect(abs((r.meters[Zone.center.rawValue] ?? 0) - 1.0) < 0.01)
    #expect(r.danger[Zone.right.rawValue] < 1.0, "3 m away is beyond the 1.5 m warning distance")
    #expect(r.meters[Zone.left.rawValue] == nil)
}

@Test func metricAnalyzerSaysStopWhenVeryClose() {
    let r = MetricZoneAnalyzer().analyze(wall(at: 0.4, from: -0.3, to: 0.3))
    #expect(r.immediateStop)
}

@Test func headHeightObstaclesCount() {
    // An open cabinet door or shelf at head height, nothing below: canes miss these.
    let r = MetricZoneAnalyzer().analyze(wall(at: 1.0, from: -0.2, to: 0.2, height: 1.5...1.8))
    #expect(r.danger[Zone.center.rawValue] >= 1.0)
}

@Test func announcerWaitsForAStableWarning() {
    var a = ObstacleAnnouncer()
    let blockedCenter = ZoneReading(danger: [0, 2, 0], meters: [nil, 1.0, nil])
    var said: [String] = []
    var t = 0.0
    for _ in 0..<5 {  // 0.5 s: not yet
        t += 0.1
        said += speech(a.update(blockedCenter, time: t))
    }
    #expect(said.isEmpty, "a single glance shouldn't trigger speech")
    for _ in 0..<20 {
        t += 0.1
        said += speech(a.update(blockedCenter, time: t))
    }
    #expect(said == ["Obstacle ahead, 1 meter, clearer on the left"])
}

@Test func announcerDoesNotFlickerAroundTheThreshold() {
    var a = ObstacleAnnouncer()
    var said: [String] = []
    var t = 0.0
    for i in 0..<100 {   // danger hovering just above / below 1.0 every frame
        t += 0.1
        said += speech(a.update(ZoneReading(danger: [0, i % 2 == 0 ? 1.05 : 0.95, 0]), time: t))
    }
    #expect(said.count <= 3)
}

@Test func announcerSaysPathClearAfterwards() {
    var a = ObstacleAnnouncer()
    var said: [String] = []
    var t = 0.0
    for _ in 0..<20 { t += 0.1; said += speech(a.update(ZoneReading(danger: [2, 0, 0]), time: t)) }
    for _ in 0..<50 { t += 0.1; said += speech(a.update(ZoneReading(danger: [0, 0, 0]), time: t)) }
    #expect(said == ["Obstacle on the left", "Path clear"])
}

@Test func immediateStopIsNotDelayed() {
    var a = ObstacleAnnouncer()
    let ev = a.update(ZoneReading(danger: [0, 5, 0], immediateStop: true), time: 0)
    #expect(ev.contains(.speak("Stop. Obstacle right in front.", urgent: true)))
}

@Test func clearerSideFollowsTheOpenSide() {
    var a = ObstacleAnnouncer()
    var said: [String] = []
    var t = 0.0
    for _ in 0..<20 { t += 0.1; said += speech(a.update(ZoneReading(danger: [1.6, 2, 0.2]), time: t)) }
    #expect(said.last == "Obstacle ahead, clearer on the right")
}

@Test func rotationMakesTheLeftEdgeTheTop() {
    // 3 wide x 2 tall:  a b c / d e f   -> rotated clockwise ->  d a / e b / f c
    let (out, w, h) = rotateClockwise([1, 2, 3, 4, 5, 6], width: 3, height: 2)
    #expect(w == 2 && h == 3)
    #expect(out == [4, 1, 5, 2, 6, 3])
}

@Test func relativeAnalyzerUsesTheFloorAsARuler() {
    let w = 30, h = 30
    var d = [Float](repeating: 1, count: w * h)      // everything as close as the floor
    var a = RelativeDepthZoneAnalyzer()
    #expect(a.analyze(depth: d, width: w, height: h).danger.allSatisfy { $0 < 1 })
    // A box in the right third, twice as close as the floor.
    for y in 6..<20 { for x in 22..<30 { d[y * w + x] = 2 } }
    let r = a.analyze(depth: d, width: w, height: h)
    #expect(r.danger[2] >= 1 && r.danger[0] < 1 && r.danger[1] < 1)
}

private func speech(_ ev: [GuidanceEvent]) -> [String] {
    ev.compactMap { if case .speak(let s, _) = $0 { return s } else { return nil } }
}
