import Foundation

// Behavior modelling during guidance:
//   NavSample          one 10 Hz snapshot of sensor signals and route context
//   FeatureExtractor   turns the recent samples into model features
//   LogisticModel      a small trainable classifier (weights can be learned from trip logs)
//   BehaviorPredictor  predicts hesitation and early turns 1-2 s before they happen
//   AdaptiveCoach      decides what to say when a problem is predicted
//   Hesitation/EarlyTurn detectors  label what actually happened (for metrics and training)

/// One snapshot of the walker during a guided trip.
public struct NavSample: Codable, Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public var height: Double
    /// Facing direction in degrees (math convention: 0 = +x, 90 = forward/+y).
    public var heading: Double
    /// Index of the route point being walked toward.
    public var target: Int
    public var distToTarget: Double
    public var distToDestination: Double
    public var distToRoute: Double
    /// Angle from facing direction to the target point (positive = target is to the left).
    public var relToTarget: Double
    /// Turn to make at the target point (positive = left); 0 if none.
    public var upcomingTurn: Double
    /// Angle from facing direction to the direction of the NEXT leg.
    public var relToNextLeg: Double
    /// Sideways offset from the current leg, positive toward the side of the upcoming turn.
    public var lateralTowardTurn: Double

    /// Build a sample from the guide's view of the route.
    public static func make(guide: Guide, position p: Vec2, heading h: Vec2, height: Double, time t: Double) -> NavSample {
        let r = guide.route
        let ti = min(guide.target, r.count - 1)
        let a = r[max(ti - 1, 0)], b = r[ti]
        let turn = guide.upcomingTurn
        let nextDir = ti + 1 < r.count ? r[ti + 1] - r[ti] : b - a
        // Signed sideways offset from the current leg (positive = left of the walking direction).
        let leg = (b - a).normalized
        let side = leg.length > 0 ? leg.cross(p - a) : 0
        let towardTurn = turn == 0 ? 0 : (turn > 0 ? side : -side)
        return NavSample(
            t: t, x: p.x, y: p.y, height: height,
            heading: atan2(h.y, h.x) * 180 / .pi,
            target: ti,
            distToTarget: p.distance(to: b),
            distToDestination: guide.remainingDistance(from: p),
            distToRoute: guide.distanceToRemainingRoute(p),
            relToTarget: signedAngle(from: h, to: b - p),
            upcomingTurn: turn,
            relToNextLeg: signedAngle(from: h, to: nextDir),
            lateralTowardTurn: towardTurn)
    }
}

/// Features describing the last few seconds of walking. All roughly in 0...1.
public struct BehaviorFeatures: Equatable, Sendable {
    public static let names = ["speed", "speedDrop", "headingRate", "oscillation",
                               "nearCorner", "turningTowardNextLeg", "lateralTowardTurn"]
    public var values: [Double]

    public init(values: [Double]) {
        self.values = values
    }
}

public struct FeatureExtractor: Sendable {
    private var history: [NavSample] = []
    public init() {}

    public mutating func reset() { history = [] }

    /// Add a sample; returns features once there are at least 1.5 s of history.
    public mutating func add(_ s: NavSample) -> BehaviorFeatures? {
        history.append(s)
        history.removeAll { s.t - $0.t > 5.0 }
        guard let first = history.first, s.t - first.t >= 1.5 else { return nil }
        return BehaviorFeatures(values: [
            min(speed(over: 1.0) / 1.2, 1.5),
            speedDrop(),
            min(headingRate(over: 1.0) / 90, 2),
            oscillation(over: 2.0),
            nearCorner(s),
            turningTowardNextLeg(s),
            max(-1, min(s.lateralTowardTurn / 1.0, 1.5)),
        ])
    }

    private func window(_ seconds: Double) -> [NavSample] {
        guard let last = history.last else { return [] }
        return history.filter { last.t - $0.t <= seconds }
    }

    /// Speed in m/s over the last `seconds`, from the net distance moved. (Summing the step
    /// lengths instead would turn tracking jitter into fake speed while standing still.)
    func speed(over seconds: Double) -> Double {
        let w = window(seconds)
        guard let a = w.first, let b = w.last, b.t > a.t else { return 0 }
        return Vec2(a.x, a.y).distance(to: Vec2(b.x, b.y)) / (b.t - a.t)
    }

    /// 0 = walking as fast as in the last 5 s; 1 = stopped.
    private func speedDrop() -> Double {
        let recent = speed(over: 1.0), usual = max(speed(over: 5.0), 0.3)
        return max(0, min(1, 1 - recent / usual))
    }

    private func headingRate(over seconds: Double) -> Double {
        let w = window(seconds)
        guard let a = w.first, let b = w.last, b.t > a.t else { return 0 }
        var total = 0.0
        for (p, q) in zip(w, w.dropFirst()) { total += abs(wrapDegrees(q.heading - p.heading)) }
        return total / (b.t - a.t)
    }

    /// Looking left and right without settling: total turning minus net turning, per 90 degrees.
    private func oscillation(over seconds: Double) -> Double {
        let w = window(seconds)
        guard let a = w.first, let b = w.last else { return 0 }
        var total = 0.0
        for (p, q) in zip(w, w.dropFirst()) { total += abs(wrapDegrees(q.heading - p.heading)) }
        return min((total - abs(wrapDegrees(b.heading - a.heading))) / 90, 2)
    }

    /// Close to a real turn (1 at the corner, fading out by ~4 m).
    private func nearCorner(_ s: NavSample) -> Double {
        abs(s.upcomingTurn) >= 20 ? exp(-s.distToTarget / 2) : 0
    }

    /// Rotating toward the next leg while still well before the corner.
    private func turningTowardNextLeg(_ s: NavSample) -> Double {
        guard abs(s.upcomingTurn) >= 20, s.distToTarget > 1.2,
              let past = window(1.0).first, past.target == s.target else { return 0 }
        let closing = abs(past.relToNextLeg) - abs(s.relToNextLeg)          // degrees turned toward it
        let leaving = abs(s.relToTarget) - abs(past.relToTarget)            // degrees turned away from the corner
        return max(0, min((closing + leaving) / 60, 1.5))
    }
}

/// Logistic regression: p = sigmoid(w . x + b). Small, explainable, and trainable from logs.
public struct LogisticModel: Codable, Equatable, Sendable {
    public var weights: [Double]
    public var bias: Double

    public init(weights: [Double], bias: Double) {
        self.weights = weights
        self.bias = bias
    }

    public func probability(_ x: [Double]) -> Double {
        let z = zip(weights, x).reduce(bias) { $0 + $1.0 * $1.1 }
        return 1 / (1 + exp(-z))
    }

    /// Batch gradient descent with L2 regularisation. Positives are up-weighted so rare
    /// events (an early turn is maybe 2% of samples) aren't ignored.
    public mutating func train(_ xs: [[Double]], _ ys: [Bool], epochs: Int = 400,
                               learningRate: Double = 0.5, l2: Double = 0.001) {
        guard !xs.isEmpty, xs.count == ys.count else { return }
        let pos = Double(ys.filter { $0 }.count), neg = Double(ys.count) - pos
        let wPos = pos > 0 ? Double(ys.count) / (2 * pos) : 1
        let wNeg = neg > 0 ? Double(ys.count) / (2 * neg) : 1
        for _ in 0..<epochs {
            var gw = [Double](repeating: 0, count: weights.count)
            var gb = 0.0
            for (x, y) in zip(xs, ys) {
                let err = (probability(x) - (y ? 1 : 0)) * (y ? wPos : wNeg)
                for j in weights.indices { gw[j] += err * x[j] }
                gb += err
            }
            let n = Double(xs.count)
            for j in weights.indices { weights[j] -= learningRate * (gw[j] / n + l2 * weights[j]) }
            bias -= learningRate * gb / n
        }
    }
}

/// Predicts the two patterns seen in testing: hesitation and turning too early.
public struct BehaviorPredictor: Codable, Equatable, Sendable {
    public var hesitation: LogisticModel
    public var earlyTurn: LogisticModel

    /// Hand-set starting weights (feature order: BehaviorFeatures.names). Replace them with
    /// weights trained on real trip logs: analysis/train_predictor.py writes predictor.json.
    public static let defaults = BehaviorPredictor(
        hesitation: LogisticModel(weights: [-6.0, 3.0, 1.0, 2.5, 1.0, 0.0, 0.0], bias: -1.0),
        earlyTurn: LogisticModel(weights: [0.5, 0.0, 1.0, 0.0, -1.5, 4.0, 3.0], bias: -3.0))

    public init(hesitation: LogisticModel, earlyTurn: LogisticModel) {
        self.hesitation = hesitation
        self.earlyTurn = earlyTurn
    }

    public func predict(_ f: BehaviorFeatures) -> (hesitation: Double, earlyTurn: Double) {
        (hesitation.probability(f.values), earlyTurn.probability(f.values))
    }
}

/// What the app says when the predictor expects trouble.
public struct AdaptiveCoach: Sendable {
    public var threshold = 0.6
    public var phrasing = Phrasing()
    private var lastHesitationCue = -Double.infinity
    private var earlyCuesForTarget: [Int: Int] = [:]
    private var lastEarlyCue = -Double.infinity

    public init() {}

    public mutating func update(sample s: NavSample, hesitation pH: Double, earlyTurn pE: Double) -> [GuidanceEvent] {
        // About to turn too soon: hold them on the current leg.
        if pE >= threshold, abs(s.upcomingTurn) >= 20, s.distToTarget > 1.5,
           earlyCuesForTarget[s.target, default: 0] < 2, s.t - lastEarlyCue >= 4 {
            earlyCuesForTarget[s.target, default: 0] += 1
            lastEarlyCue = s.t
            return [.haptic(.onTrack), .speak("Not yet. Keep straight for \(phrasing.distance(s.distToTarget)) more.", urgent: true)]
        }
        // Unsure and slowing down: reassure and restate the next step.
        if pH >= threshold, s.distToDestination > 1.5, s.t - lastHesitationCue >= 7 {
            lastHesitationCue = s.t
            let next: String
            if abs(s.upcomingTurn) >= 20 {
                next = "\(turnWords(s.upcomingTurn)) in \(phrasing.distance(s.distToTarget))."
            } else {
                next = "Keep going straight, \(phrasing.distance(s.distToTarget))."
            }
            var out: [GuidanceEvent] = []
            if abs(s.relToTarget) > 35 {
                out.append(.speak("\(headingPrompt(s.relToTarget)). Then \(next.prefix(1).lowercased() + next.dropFirst())", urgent: false))
            } else {
                out.append(.speak("You're on track. \(next)", urgent: false))
            }
            return out
        }
        return []
    }
}

// MARK: - What actually happened (ground truth for metrics and training labels)

public enum TripEventKind: String, Codable, Sendable {
    case hesitation      // stopped for 2 s or more before arriving
    case earlyTurn       // drifted 0.6 m or more toward the next leg before reaching the corner
    case offRoute
    case cue             // the adaptive coach spoke
    case arrived
    case stopped         // user cancelled
}

public struct TripEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var kind: TripEventKind
    public var detail: String

    public init(t: Double, kind: TripEventKind, detail: String = "") {
        self.t = t
        self.kind = kind
        self.detail = detail
    }
}

/// Detects hesitations and early turns from the samples themselves.
public struct BehaviorDetector: Sendable {
    public var stopSpeed = 0.15
    public var stopSeconds = 2.0
    public var earlyLateral = 0.6

    private var slowSince: Double?
    private var stopCounted = false
    private var earlyCounted: Set<Int> = []
    private var recent: [NavSample] = []

    public init() {}

    public mutating func add(_ s: NavSample) -> [TripEvent] {
        recent.append(s)
        recent.removeAll { s.t - $0.t > 1.0 }
        var out: [TripEvent] = []

        // Net distance over the last second, so tracking jitter doesn't look like walking.
        let span = (recent.last?.t ?? 0) - (recent.first?.t ?? 0)
        let moved = recent.first.map { a in Vec2(a.x, a.y).distance(to: Vec2(s.x, s.y)) } ?? 0
        let speed = span > 0.5 ? moved / span : 1
        if speed < stopSpeed, s.distToDestination > 1.5 {
            if slowSince == nil { slowSince = s.t }
            if let since = slowSince, s.t - since >= stopSeconds, !stopCounted {
                stopCounted = true
                out.append(TripEvent(t: since, kind: .hesitation, detail: String(format: "%.1f m before target", s.distToTarget)))
            }
        } else {
            slowSince = nil
            stopCounted = false
        }

        if abs(s.upcomingTurn) >= 30, s.distToTarget > 1.5, s.lateralTowardTurn >= earlyLateral,
           !earlyCounted.contains(s.target) {
            earlyCounted.insert(s.target)
            out.append(TripEvent(t: s.t, kind: .earlyTurn, detail: String(format: "%.1f m before the corner", s.distToTarget)))
        }
        return out
    }
}

// MARK: - Trip logs

/// Everything recorded about one guided trip.
public struct TripLog: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case arrived, stopped, abandoned }

    public var id: UUID
    public var participant: String
    public var started: Date
    public var destination: String
    /// Were predictive cues on for this trip? (The study compares trips with and without.)
    public var adaptive: Bool
    public var routeLength: Double
    public var outcome: Outcome
    public var samples: [NavSample]
    public var events: [TripEvent]

    public var duration: Double { (samples.last?.t ?? 0) - (samples.first?.t ?? 0) }
    public func count(_ k: TripEventKind) -> Int { events.filter { $0.kind == k }.count }
    /// Navigation errors = going off route + turning early.
    public var errors: Int { count(.offRoute) + count(.earlyTurn) }

    /// One row per sample, for spreadsheets and the Python analysis scripts.
    public func csv() -> String {
        let featureCols = BehaviorFeatures.names.map { "f_" + $0 }.joined(separator: ",")
        var rows = ["trip,participant,adaptive,destination,outcome,t,x,y,height,heading,target,dist_to_target,dist_to_destination,"
                    + "dist_to_route,rel_to_target,upcoming_turn,rel_to_next_leg,lateral_toward_turn,\(featureCols),event"]
        let t0 = samples.first?.t ?? 0
        var pending = events.sorted { $0.t < $1.t }
        var fx = FeatureExtractor()
        let blank = BehaviorFeatures.names.map { _ in "" }.joined(separator: ",")
        let dest = destination.replacingOccurrences(of: ",", with: " ")
        for s in samples {
            let feats = fx.add(s).map { $0.values.map { String(format: "%.4f", $0) }.joined(separator: ",") } ?? blank
            var ev: [String] = []
            while let e = pending.first, e.t <= s.t {
                ev.append(e.kind.rawValue)
                pending.removeFirst()
            }
            let f = { (v: Double) in String(format: "%.3f", v) }
            rows.append([id.uuidString, participant, adaptive ? "1" : "0", dest, outcome.rawValue, f(s.t - t0),
                         f(s.x), f(s.y), f(s.height), f(s.heading), "\(s.target)", f(s.distToTarget),
                         f(s.distToDestination), f(s.distToRoute), f(s.relToTarget), f(s.upcomingTurn),
                         f(s.relToNextLeg), f(s.lateralTowardTurn), feats, ev.joined(separator: "|")].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

/// Runs alongside a Guide: records samples, detects events, predicts and coaches.
public struct TripRecorder: Sendable {
    public private(set) var log: TripLog
    public var predictor: BehaviorPredictor
    public var coach = AdaptiveCoach()
    private var features = FeatureExtractor()
    private var detector = BehaviorDetector()
    public private(set) var lastPrediction: (hesitation: Double, earlyTurn: Double) = (0, 0)

    public init(participant: String, destination: String, adaptive: Bool, routeLength: Double,
                predictor: BehaviorPredictor = .defaults, started: Date = Date()) {
        log = TripLog(id: UUID(), participant: participant, started: started, destination: destination,
                      adaptive: adaptive, routeLength: routeLength, outcome: .abandoned, samples: [], events: [])
        self.predictor = predictor
    }

    /// Record one sample. Returns the coach's cues (empty when adaptive cues are off).
    public mutating func record(_ s: NavSample) -> [GuidanceEvent] {
        log.samples.append(s)
        log.events += detector.add(s)
        guard let f = features.add(s) else { return [] }
        lastPrediction = predictor.predict(f)
        guard log.adaptive else { return [] }
        let cues = coach.update(sample: s, hesitation: lastPrediction.hesitation, earlyTurn: lastPrediction.earlyTurn)
        for case .speak(let text, _) in cues { log.events.append(TripEvent(t: s.t, kind: .cue, detail: text)) }
        return cues
    }

    public mutating func note(_ kind: TripEventKind, at t: Double, detail: String = "") {
        log.events.append(TripEvent(t: t, kind: kind, detail: detail))
    }

    public mutating func finish(_ outcome: TripLog.Outcome) -> TripLog {
        log.outcome = outcome
        return log
    }

    /// Features for every sample of a finished trip, for training.
    public static func featureRows(_ log: TripLog) -> [(t: Double, features: [Double])] {
        var fx = FeatureExtractor()
        return log.samples.compactMap { s in fx.add(s).map { (s.t, $0.values) } }
    }
}
