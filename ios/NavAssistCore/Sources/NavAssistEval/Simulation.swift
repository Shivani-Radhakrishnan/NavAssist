import Foundation
import NavAssistCore

/// Randomised simulated walkers, to evaluate the hesitation / early-turn predictor before
/// real trip logs exist. Everything here is SIMULATED: speeds, behaviours and sensor noise are
/// assumptions, so results say how the detector and predictor behave under those assumptions,
/// not how real people walk.
struct WalkerSimulation {
    var rng: SplitMix64

    struct Params {
        var earlyTurnProbability = 0.35     // per corner
        var hesitationProbability = 0.35    // per trip
        var positionNoise = 0.03            // m, ARKit-like error (drifts smoothly, see below)
        var headingNoise = 3.0              // degrees
    }
    var params = Params()
    /// Tracking error that drifts smoothly (AR(1)), like visual-inertial tracking, rather than
    /// jumping independently every frame.
    private var drift = Vec2(0, 0)

    mutating func randomRoute() -> [Vec2] {
        var pts = [Vec2(0, 0)]
        var dir = Double.random(in: 0..<360, using: &rng)
        for leg in 0..<Int.random(in: 3...4, using: &rng) {
            if leg > 0 { dir += (Bool.random(using: &rng) ? 1 : -1) * Double.random(in: 50...120, using: &rng) }
            let len = Double.random(in: 3...8, using: &rng)
            let r = dir * .pi / 180
            pts.append(pts.last! + Vec2(cos(r), sin(r)) * len)
        }
        return pts
    }

    /// One trip with cues off (pure observation), recorded exactly as the app records it.
    mutating func trip(participant: String) -> TripLog {
        let route = randomRoute()
        var guide = Guide(route: route, destinationName: "Goal")
        var rec = TripRecorder(participant: participant, destination: "Goal", adaptive: false,
                               routeLength: guide.remainingDistance(from: route[0]))
        let speed = Double.random(in: 0.6...1.2, using: &rng)
        // Plan the behaviours for this trip.
        let early = (0..<route.count).map { _ in
            Double.random(in: 0...1, using: &rng) < params.earlyTurnProbability ? Double.random(in: 2.5...4.5, using: &rng) : 0
        }
        let hesitateAt = Double.random(in: 0...1, using: &rng) < params.hesitationProbability
            ? Double.random(in: 0.15...0.85, using: &rng) : -1          // fraction of the route length
        let hesitateFor = Double.random(in: 2.5...5, using: &rng)
        let total = guide.remainingDistance(from: route[0])

        var p = route[0]
        var h = (route[1] - route[0]).normalized
        var t = 0.0, walked = 0.0, stopped = 0.0
        _ = guide.start(position: p, heading: h, time: 0)
        while t < 120, !guide.finished {
            t += 0.1
            let corner = guide.target
            var aim = guide.route[corner]
            if corner < guide.route.count - 1, early.indices.contains(corner), early[corner] > 0,
               p.distance(to: guide.route[corner]) < early[corner] {
                aim = guide.route[corner + 1]                     // cuts the corner
            }
            if hesitateAt >= 0, walked >= hesitateAt * total, stopped < hesitateFor {
                stopped += 0.1
                let look = sin(stopped * 2.5) * 55 * .pi / 180     // looking left and right
                let base = atan2(h.y, h.x)
                record(&rec, &guide, p, Vec2(cos(base + look), sin(base + look)), t)
                continue
            }
            let want = signedAngle(from: h, to: (aim - p).normalized)
            let step = max(-9, min(9, want)) * .pi / 180          // up to 90 degrees per second
            h = Vec2(h.x * cos(step) - h.y * sin(step), h.x * sin(step) + h.y * cos(step))
            p = p + h * (speed * 0.1)
            walked += speed * 0.1
            record(&rec, &guide, p, h, t)
        }
        return rec.finish(guide.finished ? .arrived : .abandoned)
    }

    /// What the phone would measure (with noise), fed to the guide and the recorder.
    private mutating func record(_ rec: inout TripRecorder, _ guide: inout Guide, _ p: Vec2, _ h: Vec2, _ t: Double) {
        let n = params.positionNoise
        let kick = Vec2(Double.random(in: -1...1, using: &rng), Double.random(in: -1...1, using: &rng)) * (n * 0.25)
        drift = drift * 0.97 + kick
        let jitter = Vec2(Double.random(in: -1...1, using: &rng), Double.random(in: -1...1, using: &rng)) * 0.005
        let seenP = p + drift + jitter
        let a = atan2(h.y, h.x) + Double.random(in: -params.headingNoise...params.headingNoise, using: &rng) * .pi / 180
        let seenH = Vec2(cos(a), sin(a))
        _ = rec.record(NavSample.make(guide: guide, position: seenP, heading: seenH, height: 0, time: t))
        for e in guide.update(position: seenP, heading: seenH, time: t) {
            if e == .offRoute {
                rec.note(.offRoute, at: t)
                // Re-plan along the rest of the route, as the app does.
                let rest = Array(guide.route[guide.target...])
                guide = Guide(route: [seenP] + rest, destinationName: "Goal")
                _ = guide.start(position: seenP, heading: seenH, time: t)
            }
        }
    }
}

/// Event-level and sample-level evaluation of the predictor on simulated trips.
struct PredictorEvaluation {
    let out: URL
    let trips: Int

    func run() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var sim = WalkerSimulation(rng: SplitMix64(seed: 7))
        let logs = (0..<trips).map { sim.trip(participant: "SIM\($0 % 20)") }
        let train = logs.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let test = logs.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        print("simulated \(logs.count) trips: \(logs.map { $0.count(.earlyTurn) }.reduce(0, +)) early turns, "
              + "\(logs.map { $0.count(.hesitation) }.reduce(0, +)) hesitations")

        // Train on half the trips (label: the event starts within the next 2 s), test on the other half.
        func rows(_ logs: [TripLog], _ kind: TripEventKind) -> ([[Double]], [Bool]) {
            var xs: [[Double]] = [], ys: [Bool] = []
            for log in logs {
                let times = log.events.filter { $0.kind == kind }.map(\.t)
                for (t, f) in TripRecorder.featureRows(log) {
                    xs.append(f)
                    ys.append(times.contains { $0 > t && $0 <= t + 2 })
                }
            }
            return (xs, ys)
        }
        var trained = BehaviorPredictor.defaults
        for kind in [TripEventKind.hesitation, .earlyTurn] {
            let (xs, ys) = rows(train, kind)
            var m = LogisticModel(weights: Array(repeating: 0, count: BehaviorFeatures.names.count), bias: 0)
            m.train(xs, ys, epochs: 300, learningRate: 1.0)
            if kind == .hesitation { trained.hesitation = m } else { trained.earlyTurn = m }
        }

        let summary = CSV(out.appendingPathComponent("predictor_events.csv"),
                          header: ["model", "smoothing", "event", "threshold", "events", "detected_before_onset", "recall", "median_lead_s",
                                   "false_alarms_per_min", "sample_auc"])
        let roc = CSV(out.appendingPathComponent("predictor_roc.csv"), header: ["model", "event", "fpr", "tpr"])
        for (name, model, smooth) in [("hand-tuned", BehaviorPredictor.defaults, 0.0), ("trained", trained, 0.0),
                                      ("trained", trained, 0.7)] {
            Self.smoothing = smooth
            for kind in [TripEventKind.hesitation, .earlyTurn] {
                // Operating point chosen on the TRAINING trips: the lowest threshold that keeps false
                // alarms at or under 1 per minute. Then everything is measured on the TEST trips.
                let tuned = stride(from: 0.5, through: 0.995, by: 0.005).first {
                    Self.events(model, kind, train, threshold: $0).falseAlarmsPerMin <= 1.0
                } ?? 0.995
                let auc = Self.auc(Self.scores(model, kind, test), roc: roc, model: smooth > 0 ? name + "+smoothing" : name, event: kind.rawValue)
                for threshold in [0.6, tuned] {
                    let r = Self.events(model, kind, test, threshold: threshold)
                    summary.row([name, smooth, kind.rawValue, threshold, r.events, r.detected, Double(r.detected) / Double(max(r.events, 1)),
                                 r.medianLead ?? Double.nan, r.falseAlarmsPerMin, auc])
                    print(String(format: "%@ (smoothing %.1f) %@ @%.3f: recall %d/%d, lead %.1f s, %.2f false alarms/min, AUC %.3f",
                                 name, smooth, kind.rawValue, threshold, r.detected, r.events, r.medianLead ?? .nan, r.falseAlarmsPerMin, auc))
                }
            }
        }
        try summary.save()
        try roc.save()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(trained).write(to: out.appendingPathComponent("predictor_trained_on_simulation.json"))
    }


    struct EventResult {
        var events = 0, detected = 0
        var medianLead: Double?
        var falseAlarmsPerMin = 0.0
    }

    /// Optional exponential smoothing of the probabilities (tested as a way to cut false alarms).
    static var smoothing = 0.0

    static func probabilities(_ model: BehaviorPredictor, _ kind: TripEventKind, _ log: TripLog) -> [(t: Double, p: Double)] {
        var ema: Double?
        return TripRecorder.featureRows(log).map { row in
            let pr = model.predict(BehaviorFeatures(values: row.features))
            let raw = kind == .hesitation ? pr.hesitation : pr.earlyTurn
            let v = ema.map { smoothing * $0 + (1 - smoothing) * raw } ?? raw
            ema = v
            return (row.t, v)
        }
    }

    /// Event-level results: an event counts as predicted if the probability reached the threshold
    /// in the 3 s before it started. An alarm onset with no event in the following 3 s is a false alarm.
    static func events(_ model: BehaviorPredictor, _ kind: TripEventKind, _ logs: [TripLog], threshold: Double) -> EventResult {
        var r = EventResult()
        var leads: [Double] = []
        var falseAlarms = 0
        for log in logs {
            let times = log.events.filter { $0.kind == kind }.map(\.t)
            let probs = probabilities(model, kind, log)
            for e in times {
                r.events += 1
                if let first = probs.first(where: { $0.p >= threshold && $0.t >= e - 3 && $0.t <= e }) {
                    r.detected += 1
                    leads.append(e - first.t)
                }
            }
            var above = false
            for (t, p) in probs {
                if p >= threshold, !above, !times.contains(where: { $0 >= t - 0.5 && $0 <= t + 3 }) { falseAlarms += 1 }
                above = p >= threshold
            }
        }
        leads.sort()
        r.medianLead = leads.isEmpty ? nil : leads[leads.count / 2]
        let minutes = logs.map(\.duration).reduce(0, +) / 60
        r.falseAlarmsPerMin = Double(falseAlarms) / max(minutes, 1e-9)
        return r
    }

    /// Per-sample scores with labels (event starts within the next 2 s), for the ROC curve.
    static func scores(_ model: BehaviorPredictor, _ kind: TripEventKind, _ logs: [TripLog]) -> [(Double, Bool)] {
        logs.flatMap { log -> [(Double, Bool)] in
            let times = log.events.filter { $0.kind == kind }.map(\.t)
            return probabilities(model, kind, log).map { s in (s.p, times.contains { e in e > s.t && e <= s.t + 2 }) }
        }
    }

    /// Area under the ROC curve; also writes ~50 curve points.
    static func auc(_ scores: [(Double, Bool)], roc: CSV, model: String, event: String) -> Double {
        let sorted = scores.sorted { $0.0 > $1.0 }
        let pos = Double(sorted.filter { $0.1 }.count), neg = Double(sorted.count) - pos
        guard pos > 0, neg > 0 else { return .nan }
        var tp = 0.0, fp = 0.0, area = 0.0, prevFPR = 0.0, prevTPR = 0.0
        let every = max(1, sorted.count / 50)
        for (i, s) in sorted.enumerated() {
            if s.1 { tp += 1 } else { fp += 1 }
            let tpr = tp / pos, fpr = fp / neg
            area += (fpr - prevFPR) * (tpr + prevTPR) / 2
            prevFPR = fpr
            prevTPR = tpr
            if i % every == 0 || i == sorted.count - 1 { roc.row([model, event, fpr, tpr]) }
        }
        return area
    }
}
