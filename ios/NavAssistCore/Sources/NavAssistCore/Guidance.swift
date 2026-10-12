import Foundation

public enum HapticCue: Sendable, Equatable {
    case turnLeft, turnRight, onTrack, waypoint, arrived, offRoute, obstacle, stop
}

public enum GuidanceEvent: Sendable, Equatable {
    /// `urgent` speech interrupts whatever is being said.
    case speak(String, urgent: Bool)
    case haptic(HapticCue)
    case arrived
    /// The user has left the route; the caller should plan a new one from where they are.
    case offRoute
}

public struct GuidanceSettings: Codable, Equatable, Sendable {
    public var arriveRadius = 0.8
    public var waypointRadius = 0.9
    public var offRouteDistance = 1.5
    public var offRouteSeconds = 2.5
    /// Facing more than this many degrees away from the next point counts as off course...
    public var misalignDegrees = 35.0
    /// ...and within this many degrees counts as back on course.
    public var alignDegrees = 18.0
    public var headingPromptInterval = 4.0
    /// Warn about an upcoming turn this far before it.
    public var approachDistance = 2.0
    public var phrasing = Phrasing()

    public init() {}
}

/// Turn-by-turn guidance along one planned route.
///
/// Feed it the user's position and facing direction (from ARKit) many times a second;
/// it returns what to say and which vibration to play. It never speaks repeatedly
/// about the same thing: each leg is announced once, upcoming turns once, and
/// "turn to N o'clock" corrections at most every few seconds.
public struct Guide: Sendable {
    public let route: [Vec2]
    /// Height of each route point (nil where unknown), so arrival and turns happen on the right floor.
    public let routeHeights: [Double?]
    /// Flights of stairs (or single steps) along the route, from the recorded heights.
    public let stairs: [StairFlight]
    public let destinationName: String
    /// The map node being navigated to, so a new route can be planned after going off route.
    public var destinationNodeID: Int?
    public var settings: GuidanceSettings
    public private(set) var target = 1
    public private(set) var finished = false

    private var offSince: Double?
    private var currentHeight: Double?
    private var aligned = true
    private var lastHeadingPrompt = -Double.infinity
    private var approachAnnounced: Set<Int> = []
    private var stairsWarned: Set<Int> = []
    private var stairsStarted: Set<Int> = []
    private var stairsEnded: Set<Int> = []

    /// `heights` (one per route point, from the map) lets the guide warn about stairs.
    public init(route: [Vec2], heights: [Double?]? = nil, destinationName: String,
                settings: GuidanceSettings = GuidanceSettings()) {
        self.stairs = heights.map { findStairs(route: route, heights: $0) } ?? []
        let simple = removeShortLegs(simplifyRoute(route, tolerance: 0.35), minLength: 0.6)
        let chosen = simple.count >= 2 ? simple : (route.count == 1 ? [route[0], route[0]] : route)
        self.route = chosen
        // Simplification keeps original points, so each kept point's height is the original one.
        if let heights, heights.count == route.count {
            var used = 0
            self.routeHeights = chosen.map { pt in
                while used < route.count - 1 && route[used] != pt { used += 1 }
                return heights[min(used, heights.count - 1)]
            }
        } else {
            self.routeHeights = Array(repeating: nil, count: chosen.count)
        }
        self.destinationName = destinationName
        self.settings = settings
    }

    /// Remaining walking distance from p along the route.
    public func remainingDistance(from p: Vec2) -> Double {
        guard !finished, target < route.count else { return 0 }
        var d = p.distance(to: route[target])
        if target + 1 < route.count {
            for i in target..<(route.count - 1) { d += route[i].distance(to: route[i + 1]) }
        }
        return d
    }

    public var isLastLeg: Bool { target >= route.count - 1 }

    /// The turn (degrees, positive = left) the user will make at the point they're walking
    /// toward; 0 on the last leg.
    public var upcomingTurn: Double { turn(at: target) }
    private var say: Phrasing { settings.phrasing }

    /// Length of the leg that ends at `target`, starting from p.
    private func legLength(from p: Vec2) -> Double { p.distance(to: route[target]) }

    /// Turn the user will make at route point i (positive = left).
    private func turn(at i: Int) -> Double {
        guard i > 0, i + 1 < route.count else { return 0 }
        return wrapDegrees(signedAngle(from: route[i] - route[i - 1], to: route[i + 1] - route[i]))
    }

    public mutating func start(position p: Vec2, heading h: Vec2, time t: Double) -> [GuidanceEvent] {
        let total = remainingDistance(from: p)
        var out: [GuidanceEvent] = [.speak("Route to \(destinationName), \(say.distance(total)).", urgent: true)]
        out += legCue(position: p, heading: h, prefix: nil)
        lastHeadingPrompt = t
        return out
    }

    /// Tracking was lost (or paused): forget any half-measured "off route" time, so the first
    /// pose afterwards isn't instantly treated as having left the route.
    public mutating func pause() {
        offSince = nil
    }

    public mutating func update(position p: Vec2, heading h: Vec2, time t: Double, height: Double? = nil) -> [GuidanceEvent] {
        guard !finished else { return [] }
        currentHeight = height
        var out: [GuidanceEvent] = []

        // Arrived? (On the same floor: a bedroom directly above the kitchen isn't "arrived".)
        if p.distance(to: route[route.count - 1]) <= settings.arriveRadius,
           sameFloor(height, routeHeights[routeHeights.count - 1]) {
            finished = true
            return [.haptic(.arrived), .speak("You have arrived at \(destinationName).", urgent: true), .arrived]
        }

        // Off the route for a while?
        if distanceToRemainingRoute(p) > settings.offRouteDistance {
            if offSince == nil { offSince = t }
            if let s = offSince, t - s >= settings.offRouteSeconds {
                finished = true
                return [.haptic(.offRoute), .offRoute]
            }
        } else {
            offSince = nil
        }

        // Reached (or walked past) the next point? Move on and announce the new leg.
        while !isLastLeg && reachedTarget(p) {
            let turnHere = turn(at: target)
            target += 1
            aligned = true
            out.append(.haptic(abs(turnHere) < 20 ? .waypoint : turnHere > 0 ? .turnLeft : .turnRight))
            out += legCue(position: p, heading: h, prefix: turnWords(turnHere) + " now")
            lastHeadingPrompt = t
        }

        out += stairCues(p)

        // Upcoming turn warning, once per turn.
        if !isLastLeg, !approachAnnounced.contains(target) {
            let d = p.distance(to: route[target])
            let tw = turn(at: target)
            if d <= settings.approachDistance, d > settings.waypointRadius, abs(tw) >= 20 {
                approachAnnounced.insert(target)
                out.append(.speak("In \(say.distance(d)), \(turnWords(tw).lowercased()).", urgent: false))
            }
        }

        // Facing the wrong way? Give a clock-face correction; confirm when fixed.
        let rel = signedAngle(from: h, to: route[target] - p)
        if abs(rel) > settings.misalignDegrees {
            aligned = false
            if t - lastHeadingPrompt >= settings.headingPromptInterval {
                lastHeadingPrompt = t
                out.append(.haptic(rel > 0 ? .turnLeft : .turnRight))
                out.append(.speak(headingPrompt(rel), urgent: false))
            }
        } else if !aligned && abs(rel) <= settings.alignDegrees {
            aligned = true
            out.append(.haptic(.onTrack))
            out.append(.speak("Straight ahead", urgent: false))
        }
        return out
    }

    /// Full status for a "Where am I / repeat" button press.
    public func status(position p: Vec2, heading h: Vec2) -> String {
        guard !finished else { return "No active route." }
        var parts = ["\(destinationName) is \(say.distance(remainingDistance(from: p))) away."]
        let rel = signedAngle(from: h, to: route[target] - p)
        if abs(rel) > settings.misalignDegrees { parts.append(headingPrompt(rel) + ".") }
        if isLastLeg {
            parts.append("Walk \(say.distance(legLength(from: p))) to arrive.")
        } else {
            parts.append("Walk \(say.distance(legLength(from: p))), then \(turnWords(turn(at: target)).lowercased()).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Helpers

    private mutating func stairCues(_ p: Vec2) -> [GuidanceEvent] {
        var out: [GuidanceEvent] = []
        for (i, f) in stairs.enumerated() {
            let toStart = p.distance(to: f.start)
            if !stairsWarned.contains(i), toStart <= 4, toStart > 1.2 {
                stairsWarned.insert(i)
                out.append(.haptic(.obstacle))
                out.append(.speak("\(f.description.prefix(1).uppercased() + f.description.dropFirst()) "
                                  + "in \(say.distance(toStart)). \(f.steps > 2 ? "Hold the handrail." : "")", urgent: true))
            }
            if !stairsStarted.contains(i), toStart <= 1.2 {
                stairsWarned.insert(i)
                stairsStarted.insert(i)
                out.append(.haptic(.stop))
                out.append(.speak(f.steps == 1 ? "Step \(f.goingUp ? "up" : "down") now."
                                  : "Stairs now, going \(f.goingUp ? "up" : "down").", urgent: true))
            }
            if stairsStarted.contains(i), !stairsEnded.contains(i), f.steps > 1, p.distance(to: f.end) <= 0.8 {
                stairsEnded.insert(i)
                out.append(.haptic(.onTrack))
                out.append(.speak("End of stairs.", urgent: false))
            }
        }
        return out
    }

    private mutating func legCue(position p: Vec2, heading h: Vec2, prefix: String?) -> [GuidanceEvent] {
        let rel = signedAngle(from: h, to: route[target] - p)
        let walk = "walk \(say.distance(legLength(from: p)))"
        var sentence: String
        if let prefix {
            // "Turn right now" already says which way; a clock correction on top is noise.
            // Stay "not aligned" so the user hears "Straight ahead" once they've turned.
            aligned = abs(rel) <= settings.alignDegrees
            return [.speak("\(prefix). Then \(walk).", urgent: true)]
        }
        if abs(rel) > settings.misalignDegrees {
            aligned = false
            sentence = "\(headingPrompt(rel)), then \(walk)"
        } else {
            sentence = "Walk straight ahead, \(say.distance(legLength(from: p)))"
        }
        var out: [GuidanceEvent] = []
        if !aligned { out.append(.haptic(rel > 0 ? .turnLeft : .turnRight)) }
        out.append(.speak(sentence + ".", urgent: false))
        return out
    }

    private func reachedTarget(_ p: Vec2) -> Bool {
        guard sameFloor(currentHeight, routeHeights[target]) else { return false }
        if p.distance(to: route[target]) <= settings.waypointRadius { return true }
        // Walked past the corner: the next leg is now closer than the current one.
        let cur = closestPointOnSegment(p, route[target - 1], route[target])
        let next = distanceToSegment(p, route[target], route[target + 1])
        return cur.t >= 0.95 && next < p.distance(to: cur.point)
    }

    public func distanceToRemainingRoute(_ p: Vec2) -> Double {
        var best = Double.infinity
        for i in (target - 1)..<(route.count - 1) {
            best = min(best, distanceToSegment(p, route[i], route[i + 1]))
        }
        return best
    }
}

/// Douglas-Peucker: drop route points that are within `tolerance` meters of a straight
/// line through their neighbours, so ARKit wobble doesn't become a stream of tiny turns.
public func simplifyRoute(_ pts: [Vec2], tolerance: Double) -> [Vec2] {
    guard pts.count > 2 else { return pts }
    var keep = [Bool](repeating: false, count: pts.count)
    keep[0] = true
    keep[pts.count - 1] = true
    var stack = [(0, pts.count - 1)]
    while let (a, b) = stack.popLast() {
        guard b > a + 1 else { continue }
        var worst = (index: a, dist: 0.0)
        for i in (a + 1)..<b {
            let d = distanceToSegment(pts[i], pts[a], pts[b])
            if d > worst.dist { worst = (i, d) }
        }
        if worst.dist > tolerance {
            keep[worst.index] = true
            stack.append((a, worst.index))
            stack.append((worst.index, b))
        }
    }
    return pts.indices.filter { keep[$0] }.map { pts[$0] }
}


/// A flight of stairs (or a single step) found from the heights recorded along a route.
public struct StairFlight: Equatable, Sendable {
    public var start: Vec2
    public var end: Vec2
    /// Positive = going up, in meters.
    public var rise: Double
    public var goingUp: Bool { rise > 0 }
    /// Typical stair riser is about 17 cm.
    public var steps: Int { max(1, Int((abs(rise) / 0.17).rounded())) }

    public var description: String {
        if steps == 1 { return "a step \(goingUp ? "up" : "down")" }
        return "stairs going \(goingUp ? "up" : "down"), about \(steps) steps"
    }
}

/// Stretches where the height changes steeply (more than 30 cm per meter walked) are stairs;
/// ramps and ARKit's slow height drift are far gentler than that.
public func findStairs(route: [Vec2], heights: [Double?]) -> [StairFlight] {
    guard route.count == heights.count, route.count >= 2 else { return [] }
    var flights: [StairFlight] = []
    var current: (startIndex: Int, endIndex: Int, rise: Double)?
    func close() {
        if let c = current, abs(c.rise) >= 0.12 {
            flights.append(StairFlight(start: route[c.startIndex], end: route[c.endIndex], rise: c.rise))
        }
        current = nil
    }
    for i in 0..<(route.count - 1) {
        guard let h0 = heights[i], let h1 = heights[i + 1] else { close(); continue }
        let dh = h1 - h0
        let d = route[i].distance(to: route[i + 1])
        let steep = abs(dh) >= 0.08 && abs(dh) / max(d, 0.05) >= 0.3
        if steep, let c = current, (c.rise > 0) == (dh > 0) {
            current = (c.startIndex, i + 1, c.rise + dh)
        } else if steep {
            close()
            current = (i, i + 1, dh)
        } else {
            close()
        }
    }
    close()
    return flights
}

/// Merge legs shorter than `minLength` into their neighbours (keeping both ends of the
/// route), so a wobble at a corner doesn't become an extra "turn" instruction.
public func removeShortLegs(_ pts: [Vec2], minLength: Double) -> [Vec2] {
    var p = pts
    var changed = true
    while changed && p.count > 2 {
        changed = false
        for i in 0..<(p.count - 1) where p[i].distance(to: p[i + 1]) < minLength {
            if i + 1 < p.count - 1 {
                p.remove(at: i + 1)      // drop the corner after the short piece
            } else if i > 0 {
                p.remove(at: i)          // short last piece: drop the corner before it
            } else {
                continue
            }
            changed = true
            break
        }
    }
    return p
}
