import Foundation

/// Left / center / right, as seen by someone holding the phone in front of their chest.
public enum Zone: Int, CaseIterable, Sendable {
    case left, center, right
    public var name: String { ["left", "center", "right"][rawValue] }
}

/// One 3-D point in front of the user, relative to where they face.
public struct ObstaclePoint: Sendable {
    /// Meters to the right (negative = left).
    public var lateral: Double
    /// Meters ahead.
    public var forward: Double
    /// Meters above the floor.
    public var height: Double

    public init(lateral: Double, forward: Double, height: Double) {
        self.lateral = lateral
        self.forward = forward
        self.height = height
    }
}

/// What the analyzers hand to the state machine: per zone, how dangerous it looks.
/// 1.0 or more means "blocked". `meters` is filled in when real distances are known.
public struct ZoneReading: Sendable {
    public var danger: [Double]
    public var meters: [Double?]
    /// Something is so close in front that the user should stop right away.
    public var immediateStop: Bool
    /// Doors and stairs recognised in the same frame.
    public var hints: SceneHints

    public init(danger: [Double], meters: [Double?] = [nil, nil, nil], immediateStop: Bool = false,
                hints: SceneHints = SceneHints()) {
        self.danger = danger
        self.meters = meters
        self.immediateStop = immediateStop
        self.hints = hints
    }
}

// MARK: - LiDAR (real distances)

/// For iPhones with LiDAR: real 3-D points, so obstacles get real distances, and the
/// floor and ceiling can be removed by height instead of guessing from the picture.
public struct MetricZoneAnalyzer: Sendable {
    public var bodyHalfWidth = 0.3      // the walking corridor ("ahead") is 60 cm wide
    public var sideReach = 1.0          // side zones reach this far left/right
    public var warnDistance = 1.5       // obstacles ahead closer than this are reported
    /// Things beside the path (a basket, a chair against the wall) only matter when you're
    /// about to brush past them.
    public var sideWarnDistance = 0.7
    public var stopDistance = 0.6       // ...and closer than this in the center: "Stop"
    public var maxRange = 4.0
    public var minHeight = 0.12         // ignore the floor (and tiny bumps under 12 cm)
    public var maxHeight = 2.0          // ignore the ceiling; keeps head-height obstacles
    public var minPoints = 12           // fewer points than this in a zone is just noise

    public init() {}

    public func analyze(_ points: [ObstaclePoint]) -> ZoneReading {
        var buckets: [[Double]] = [[], [], []]
        for p in points where p.forward > 0.15 && p.forward < maxRange
            && p.height >= minHeight && p.height <= maxHeight {
            let zone: Zone
            if abs(p.lateral) <= bodyHalfWidth {
                zone = .center
            } else if p.lateral < 0, p.lateral >= -sideReach {
                zone = .left
            } else if p.lateral > 0, p.lateral <= sideReach {
                zone = .right
            } else {
                continue
            }
            buckets[zone.rawValue].append(p.forward)
        }
        var danger = [0.0, 0.0, 0.0]
        var meters: [Double?] = [nil, nil, nil]
        for z in 0..<3 where buckets[z].count >= minPoints {
            let near = percentile(buckets[z], 0.05)      // nearest 5%, ignoring stray points
            meters[z] = near
            let limit = z == Zone.center.rawValue ? warnDistance : sideWarnDistance
            danger[z] = limit / max(near, 0.05)
        }
        let stop = (meters[Zone.center.rawValue] ?? .infinity) < stopDistance
        return ZoneReading(danger: danger, meters: meters, immediateStop: stop)
    }
}

// MARK: - Camera only (relative depth from a neural network)

/// For iPhones without LiDAR: a depth network gives *relative* depth (bigger = closer)
/// with no units. As in the Python prototype (step11.py), the floor just in front of
/// the user is the ruler: a zone that looks much closer than that floor is blocked.
public struct RelativeDepthZoneAnalyzer: Sendable {
    public var floorRows = (0.85, 1.00)
    public var floorCols = (0.30, 0.70)
    public var zoneRows = (0.15, 0.75)
    /// A zone is blocked when it looks this many times closer than the floor ruler.
    public var warnRatio = 1.5

    private var floorRef: Double?
    private var lastTime: Double?
    private var atFeetFrames = 0
    /// "Something at your feet" this many frames in a row with nothing else confirming it means
    /// the ruler itself is wrong (e.g. it was set from an unusual frame), so it is re-seeded.
    public var maxAtFeetFrames = 10

    public init() {}

    /// `depth` is row-major, `width` x `height`, already rotated upright, bigger = closer.
    /// Pass `time` (seconds) when frames can be far apart: a ruler older than 1 s is dropped,
    /// because the network's scale changes from frame to frame.
    public mutating func analyze(depth: [Float], width: Int, height: Int, time: Double? = nil) -> ZoneReading {
        guard width > 0, height > 0, depth.count == width * height else {
            return ZoneReading(danger: [0, 0, 0])
        }
        if let t = time {
            if let last = lastTime, t - last > 1.0 { floorRef = nil; atFeetFrames = 0 }
            lastTime = t
        }
        let floorNow = max(median(region(depth, width, height, floorRows, floorCols)), 1e-6)
        if let ref = floorRef {
            if floorNow < 1.5 * ref {
                floorRef = 0.9 * ref + 0.1 * floorNow
                atFeetFrames = 0
            } else {
                atFeetFrames += 1
                if atFeetFrames > maxAtFeetFrames {   // stuck: trust the current floor instead
                    floorRef = floorNow
                    atFeetFrames = 0
                }
            }
        } else {
            floorRef = floorNow
        }
        let ref = floorRef ?? floorNow
        var danger = [Double]()
        for z in 0..<3 {
            let cols = (Double(z) / 3, Double(z + 1) / 3)
            let near = percentile(region(depth, width, height, zoneRows, cols), 0.90)
            danger.append(near / ref / warnRatio)
        }
        // The floor ruler itself suddenly looks much closer: something is at your feet.
        let atFeet = floorNow >= 1.5 * ref
        if atFeet { danger[Zone.center.rawValue] = max(danger[Zone.center.rawValue], 1.5) }
        return ZoneReading(danger: danger, immediateStop: atFeet)
    }

    private func region(_ d: [Float], _ w: Int, _ h: Int,
                        _ rows: (Double, Double), _ cols: (Double, Double)) -> [Double] {
        let y0 = Int(rows.0 * Double(h)), y1 = max(Int(rows.1 * Double(h)), y0 + 1)
        let x0 = Int(cols.0 * Double(w)), x1 = max(Int(cols.1 * Double(w)), x0 + 1)
        var out: [Double] = []
        out.reserveCapacity((y1 - y0) * (x1 - x0))
        for y in y0..<min(y1, h) {
            for x in x0..<min(x1, w) { out.append(Double(d[y * w + x])) }
        }
        return out
    }
}

/// Rotate a row-major image 90 degrees clockwise (camera buffers are landscape; a phone
/// held upright needs this to make "up" in the array mean "up" in the world).
public func rotateClockwise(_ d: [Float], width w: Int, height h: Int) -> (data: [Float], width: Int, height: Int) {
    var out = [Float](repeating: 0, count: w * h)
    for y2 in 0..<w {
        for x2 in 0..<h {
            out[y2 * h + x2] = d[(h - 1 - x2) * w + y2]
        }
    }
    return (out, h, w)
}

// MARK: - Turning readings into calm, non-flickering speech

/// Decides when to speak obstacle warnings. Ported from step11.py: smoothing, a delay
/// before a zone counts as blocked or clear, a gap between the two thresholds so it
/// doesn't flicker, and repeats only every few seconds.
public struct ObstacleAnnouncer: Sendable {
    public var smoothing = 0.4
    public var blockSeconds = 0.4
    public var clearSeconds = 1.0
    public var clearRatio = 0.85
    public var stableSeconds = 0.6
    public var pathClearSeconds = 2.0
    public var repeatSeconds = 4.0
    public var sideMargin = 0.15
    public var phrasing = Phrasing()

    public private(set) var blocked = [false, false, false]
    private var smooth: [Double]?
    private var changingSince: [Double?] = [nil, nil, nil]
    private var side: String?
    private var spoken: String?
    private var lastSaid = -Double.infinity
    private var pending: String?
    private var pendingSince = 0.0
    private var clearSince: Double?
    private var stopSaidAt = -Double.infinity
    private var stairsSaidAt = -Double.infinity
    private var stairsSeenSince: Double?
    private var stairsInViewSaidAt = -Double.infinity
    private var lastHints = SceneHints()

    public init() {}

    public mutating func reset() {
        let keep = phrasing
        self = ObstacleAnnouncer()
        phrasing = keep
    }

    public mutating func update(_ r: ZoneReading, time t: Double) -> [GuidanceEvent] {
        lastHints = r.hints
        // Stairs and drop-offs come first: seen in two readings in a row, then said at once.
        if let s = r.hints.stairs {
            if stairsSeenSince == nil { stairsSeenSince = t }
            if let since = stairsSeenSince, t - since >= 0.15, t - stairsSaidAt >= 6 {
                stairsSaidAt = t
                let what = s.direction == .down ? "Stairs or a drop going down" : "Steps going up"
                return [.haptic(.stop), .speak("Careful. \(what), \(phrasing.distance(s.distance)) ahead. Stop and find the handrail.", urgent: true)]
            }
        } else {
            stairsSeenSince = nil
        }
        if r.hints.stairsInView, t - stairsInViewSaidAt >= 15, t - stairsSaidAt >= 6 {
            stairsInViewSaidAt = t
            return [.haptic(.obstacle), .speak("Stairs may be ahead. Slow down.", urgent: false)]
        }
        if r.immediateStop {
            // Never delay this one; repeat every 2 s while it lasts.
            if t - stopSaidAt >= 2 {
                stopSaidAt = t
                spoken = "stop"
                lastSaid = t
                return [.haptic(.stop), .speak("Stop. Obstacle right in front.", urgent: true)]
            }
            return []
        }

        let s: [Double] = smooth.map { old in zip(old, r.danger).map { (1 - smoothing) * $0 + smoothing * $1 } } ?? r.danger
        smooth = s

        for k in 0..<3 {
            let wantsChange = blocked[k] ? s[k] < clearRatio : s[k] >= 1.0
            let need = blocked[k] ? clearSeconds : blockSeconds
            if !wantsChange {
                changingSince[k] = nil
            } else if let since = changingSince[k] {
                if t - since >= need {
                    blocked[k].toggle()
                    changingSince[k] = nil
                }
            } else {
                changingSince[k] = t
            }
        }

        side = blocked[1] ? clearerSide(s) : nil
        let msg = warningText(meters: r.meters)
        if msg != pending {
            pending = msg
            pendingSince = t
        }
        let stable = t - pendingSince >= stableSeconds

        var out: [GuidanceEvent] = []
        if msg == nil {
            if clearSince == nil { clearSince = t }
            if spoken != nil, let c = clearSince, t - c >= pathClearSeconds {
                out.append(.speak("Path clear", urgent: false))
                spoken = nil
            }
        } else if let msg {
            clearSince = nil
            if stable && (msg != spoken || t - lastSaid >= repeatSeconds) {
                out.append(.haptic(.obstacle))
                out.append(.speak(msg, urgent: msg != spoken && blocked[1]))
                spoken = msg
                lastSaid = t
            }
        }
        return out
    }

    private mutating func clearerSide(_ s: [Double]) -> String {
        if blocked[0] != blocked[2] { return blocked[0] ? "right" : "left" }
        let best = s[0] <= s[2] ? "left" : "right"
        if let prev = side, best != prev, abs(s[0] - s[2]) < sideMargin { return prev }
        return best
    }

    private func warningText(meters: [Double?]) -> String? {
        let (l, c, r) = (blocked[0], blocked[1], blocked[2])
        if c {
            var ahead = "Obstacle ahead"
            if let door = lastHints.doorAhead, abs(door - (meters[1] ?? door)) < 0.8 {
                return "Door ahead, \(phrasing.distance(door)). Reach forward for the handle."
            }
            if let m = meters[1] { ahead += ", \(phrasing.distance(m))" }
            if l && r { return ahead + ". Stop." }
            return ahead + ", clearer on the \(side ?? "left")"
        }
        if l && r { return "Obstacles on both sides" }
        if l { return "Obstacle on the left" }
        if r { return "Obstacle on the right" }
        return nil
    }
}

// MARK: - Small statistics helpers

func percentile(_ values: [Double], _ q: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let i = min(max(Int((Double(sorted.count - 1) * q).rounded()), 0), sorted.count - 1)
    return sorted[i]
}

func median(_ values: [Double]) -> Double { percentile(values, 0.5) }
