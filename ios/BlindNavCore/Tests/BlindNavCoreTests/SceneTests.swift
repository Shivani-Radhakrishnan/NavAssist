import Foundation
import Testing
@testable import BlindNavCore

// MARK: - Relative depth -> meters

@Test func recoversMetersFromFeaturePoints() {
    // Network value = 2.0 / meters + 0.3, plus noise and a few bad ARKit points.
    var rng = SystemRandomNumberGenerator()
    var r: [Double] = [], d: [Double] = []
    for i in 0..<120 {
        let m = 0.5 + Double(i % 40) * 0.1
        r.append(2.0 / m + 0.3 + Double.random(in: -0.02...0.02, using: &rng))
        d.append(m)
    }
    for _ in 0..<15 { r.append(Double.random(in: 0...5, using: &rng)); d.append(Double.random(in: 0.5...4, using: &rng)) }
    let fit = InverseDepthFit.fit(networkValues: r, meters: d)
    #expect(fit != nil)
    #expect(abs(fit!.a - 2.0) < 0.15)
    #expect(abs((fit!.meters(2.0 / 1.5 + 0.3) ?? 0) - 1.5) < 0.1)
}

@Test func refusesToGuessFromBadData() {
    #expect(InverseDepthFit.fit(networkValues: [1, 2, 3], meters: [1, 2, 3]) == nil, "too few points")
    // Bigger network value for FARTHER points: wrong way round, don't trust it.
    let m = (0..<30).map { 0.5 + Double($0) * 0.1 }
    #expect(InverseDepthFit.fit(networkValues: m.map { $0 * 2 }, meters: m) == nil)
}

// MARK: - The basket on the right

func box(lateral: ClosedRange<Double>, forward: ClosedRange<Double>, height: ClosedRange<Double>) -> [ObstaclePoint] {
    var pts: [ObstaclePoint] = []
    for x in stride(from: lateral.lowerBound, through: lateral.upperBound, by: 0.04) {
        for f in stride(from: forward.lowerBound, through: forward.upperBound, by: 0.04) {
            for h in stride(from: height.lowerBound, through: height.upperBound, by: 0.05) {
                pts.append(ObstaclePoint(lateral: x, forward: f, height: h))
            }
        }
    }
    return pts
}

@Test func aBasketBesideThePathIsNotAnObstacleAhead() {
    let basket = box(lateral: 0.45...0.8, forward: 1.0...1.3, height: 0.12...0.4)
    let r = MetricZoneAnalyzer().analyze(floorPoints() + basket)
    #expect(r.danger[Zone.center.rawValue] < 1, "basket is outside the walking corridor")
    #expect(r.danger[Zone.right.rawValue] < 1, "and 1 m away, so not worth mentioning yet")
}

@Test func theBasketIsMentionedWhenYouAreAboutToBrushPastIt() {
    let basket = box(lateral: 0.4...0.75, forward: 0.45...0.7, height: 0.12...0.4)
    let r = MetricZoneAnalyzer().analyze(basket)
    #expect(r.danger[Zone.right.rawValue] >= 1)
    #expect(r.danger[Zone.center.rawValue] < 1)
}

// MARK: - Doors

@Test func aClosedDoorIsCalledADoor() {
    var a = ObstacleAnnouncer()
    let reading = ZoneReading(danger: [0, 2, 0], meters: [nil, 1.2, nil], hints: SceneHints(doorAhead: 1.3))
    var said: [String] = []
    var t = 0.0
    for _ in 0..<20 { t += 0.1; said += speech(a.update(reading, time: t)) }
    #expect(said == ["Door ahead, 1.5 meters. Reach forward for the handle."])
}

// MARK: - Stairs

func floorWithProfile(_ heightAt: (Double) -> Double?) -> [ObstaclePoint] {
    var pts: [ObstaclePoint] = []
    for f in stride(from: 0.4, through: 3.5, by: 0.05) {
        guard let h = heightAt(f) else { continue }
        for x in stride(from: -0.4, through: 0.4, by: 0.1) { pts.append(ObstaclePoint(lateral: x, forward: f, height: h)) }
    }
    return pts
}

@Test func flatFloorHasNoStairs() {
    #expect(StairDetector().detect(floorWithProfile { _ in 0 }) == nil)
}

@Test func findsStairsGoingDown() {
    // Flat for 1.5 m, then each 28 cm tread is 17 cm lower.
    let pts = floorWithProfile { f in f < 1.5 ? 0 : -0.17 * (1 + floor((f - 1.5) / 0.28)) }
    let cue = StairDetector().detect(pts)
    #expect(cue?.direction == .down)
    #expect(abs((cue?.distance ?? 0) - 1.6) < 0.3)
}

@Test func findsStepsGoingUp() {
    let pts = floorWithProfile { f in f < 1.2 ? 0 : 0.17 * (1 + floor((f - 1.2) / 0.28)) }
    let cue = StairDetector().detect(pts)
    #expect(cue?.direction == .up)
    #expect(abs((cue?.distance ?? 0) - 1.3) < 0.3)
}

@Test func aWallIsNotStairsUp() {
    let wall = box(lateral: -0.5...0.5, forward: 2.0...2.05, height: 0...2.0)
    #expect(StairDetector().detect(floorWithProfile { $0 < 2.0 ? 0 : nil } + wall) == nil)
}

@Test func stairsAreAnnouncedFirstAndUrgently() {
    var a = ObstacleAnnouncer()
    let r = ZoneReading(danger: [0, 2, 0], meters: [nil, 1.0, nil],
                        hints: SceneHints(stairs: StairCue(direction: .down, distance: 1.6)))
    let first = a.update(r, time: 0)
    let second = a.update(r, time: 0.2)
    #expect(first.isEmpty, "needs two readings in a row, so one noisy frame can't cry wolf")
    #expect(second.contains(.speak("Careful. Stairs or a drop going down, 1.5 meters ahead. Stop and find the handrail.", urgent: true)))
    #expect(second.contains(.haptic(.stop)))
}

private func speech(_ ev: [GuidanceEvent]) -> [String] {
    ev.compactMap { if case .speak(let s, _) = $0 { return s } else { return nil } }
}
