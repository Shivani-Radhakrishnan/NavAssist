import Foundation
import Testing
@testable import NavAssistCore

enum WalkerStyle {
    case follows                    // walks exactly to each corner
    case turnsEarly(by: Double)     // heads for the next leg this many meters before the corner
    case hesitates(at: Double, seconds: Double)   // stops this far before the first corner, looking around
}

/// L-shaped route: 8 m north, then right (east) 6 m.
let lRoute = [Vec2(0, 0), Vec2(0, 8), Vec2(6, 8)]

/// Simulates a walker at 1 m/s through `lRoute`, feeding a TripRecorder at 10 Hz.
func simulateTrip(_ style: WalkerStyle, adaptive: Bool, obeysCues: Bool = false)
    -> (log: TripLog, said: [String], predictions: [(t: Double, h: Double, e: Double)]) {
    var guide = Guide(route: lRoute, destinationName: "Door")
    var rec = TripRecorder(participant: "P0", destination: "Door", adaptive: adaptive, routeLength: 14)
    var p = Vec2(0, 0), h = Vec2(0, 1)
    var said: [String] = []
    var preds: [(Double, Double, Double)] = []
    var t = 0.0
    var stoppedFor = 0.0
    var heldStraightUntil = -1.0
    _ = guide.start(position: p, heading: h, time: 0)
    while t < 60 && !guide.finished {
        t += 0.1
        var aim = guide.route[guide.target]
        switch style {
        case .follows:
            break
        case .turnsEarly(let early):
            // Cut toward the end of the next leg once within `early` m of the corner...
            if guide.target == 1, p.distance(to: lRoute[1]) < early, t > heldStraightUntil { aim = lRoute[2] }
        case .hesitates(let at, let seconds):
            if guide.target == 1, lRoute[1].y - p.y <= at, stoppedFor < seconds {
                stoppedFor += 0.1
                let look = sin(stoppedFor * 3) * 60 * .pi / 180          // looking left and right
                h = Vec2(-sin(look), cos(look))
                let s = NavSample.make(guide: guide, position: p, heading: h, height: 0, time: t)
                let cues = rec.record(s)
                said += cues.compactMap { if case .speak(let x, _) = $0 { return x } else { return nil } }
                preds.append((t, rec.lastPrediction.hesitation, rec.lastPrediction.earlyTurn))
                continue
            }
        }
        let dir = (aim - p).normalized
        // Turn at up to 90 deg/s like a person, then step.
        let want = signedAngle(from: h, to: dir)
        let step = max(-9, min(9, want)) * .pi / 180
        h = Vec2(h.x * cos(step) - h.y * sin(step), h.x * sin(step) + h.y * cos(step))
        p = p + h * 0.1
        let s = NavSample.make(guide: guide, position: p, heading: h, height: 0, time: t)
        let cues = rec.record(s)
        let spoken = cues.compactMap { if case .speak(let x, _) = $0 { return x } else { return nil } }
        said += spoken
        if obeysCues, spoken.contains(where: { $0.hasPrefix("Not yet") }) { heldStraightUntil = t + 3 }
        preds.append((t, rec.lastPrediction.hesitation, rec.lastPrediction.earlyTurn))
        for e in guide.update(position: p, heading: h, time: t) {
            if e == .offRoute { rec.note(.offRoute, at: t) }
            if e == .arrived { rec.note(.arrived, at: t) }
        }
    }
    return (rec.finish(guide.finished ? .arrived : .abandoned), said, preds)
}

@Test func aWalkerWhoFollowsHasNoErrorsAndHearsNoCues() {
    let r = simulateTrip(.follows, adaptive: true)
    #expect(r.log.errors == 0)
    #expect(r.log.count(.hesitation) == 0)
    #expect(r.said.isEmpty, "said: \(r.said)")
    #expect(r.predictions.allSatisfy { $0.h < 0.6 && $0.e < 0.6 })
}

@Test func detectsAnEarlyTurn() {
    let r = simulateTrip(.turnsEarly(by: 4), adaptive: false)
    #expect(r.log.count(.earlyTurn) == 1)
    let event = r.log.events.first { $0.kind == .earlyTurn }!
    #expect(event.detail.contains("before the corner"))
}

@Test func predictsTheEarlyTurnBeforeItHappens() {
    let r = simulateTrip(.turnsEarly(by: 4), adaptive: false)
    let happened = r.log.events.first { $0.kind == .earlyTurn }!.t
    let predicted = r.predictions.first { $0.e >= 0.6 }?.t
    #expect(predicted != nil)
    #expect(predicted! < happened, "predicted at \(predicted!), happened at \(happened)")
}

@Test func coachHoldsAnEarlyTurnerOnTheLeg() {
    let r = simulateTrip(.turnsEarly(by: 4), adaptive: true)
    #expect(r.said.contains { $0.hasPrefix("Not yet. Keep straight for") }, "said: \(r.said)")
    #expect(r.log.count(.cue) >= 1)
}

@Test func cuesReduceErrorsWhenTheWalkerListens() {
    // Not evidence about real people, only that the loop works end to end:
    // a walker who obeys "Not yet" makes fewer early turns than one with cues off.
    let without = simulateTrip(.turnsEarly(by: 4), adaptive: false)
    let with = simulateTrip(.turnsEarly(by: 4), adaptive: true, obeysCues: true)
    #expect(with.log.errors < without.log.errors)
}

@Test func detectsAndPredictsHesitation() {
    let r = simulateTrip(.hesitates(at: 2.5, seconds: 3.5), adaptive: true)
    #expect(r.log.count(.hesitation) == 1)
    #expect(r.predictions.contains { $0.h >= 0.6 })
    #expect(r.said.contains { $0.hasPrefix("You're on track") || $0.contains("o'clock") }, "said: \(r.said)")
}

@Test func adaptiveOffMeansSilentButStillMeasured() {
    let r = simulateTrip(.hesitates(at: 2.5, seconds: 3.5), adaptive: false)
    #expect(r.said.isEmpty)
    #expect(r.log.count(.hesitation) == 1)
}

@Test func logisticModelLearnsASeparableRule() {
    // y = 1 when feature 0 > 0.5.
    var xs: [[Double]] = [], ys: [Bool] = []
    for i in 0..<200 {
        let v = Double(i) / 200
        xs.append([v, Double(i % 7) / 7])
        ys.append(v > 0.5)
    }
    var m = LogisticModel(weights: [0, 0], bias: 0)
    m.train(xs, ys, epochs: 2000, learningRate: 2)
    #expect(m.probability([0.9, 0.3]) > 0.8)
    #expect(m.probability([0.1, 0.3]) < 0.2)
}

@Test func tripLogExportsCSV() throws {
    let r = simulateTrip(.turnsEarly(by: 4), adaptive: true)
    let lines = r.log.csv().split(separator: "\n")
    #expect(lines.first?.hasPrefix("trip,participant,adaptive,destination,outcome,route,t,") == true)
    #expect(lines.first?.contains("f_speed") == true)
    #expect(lines.count == r.log.samples.count + 1)
    #expect(lines.contains { $0.hasSuffix("earlyTurn") || $0.contains("earlyTurn|") || $0.contains("|earlyTurn") })
    let back = try JSONDecoder().decode(TripLog.self, from: JSONEncoder().encode(r.log))
    #expect(back == r.log)
}
