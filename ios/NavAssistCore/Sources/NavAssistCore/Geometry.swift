import Foundation

/// A point or direction on the floor, in meters, seen from above.
///
/// ARKit's world has y pointing up and the camera starting out looking along -z.
/// `Vec2(fromWorldX:z:)` maps that onto ordinary math axes: +x = right, +y = forward,
/// so a positive (counter-clockwise) angle always means LEFT, as in the Python prototype.
public struct Vec2: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(fromWorldX x: Float, z: Float) {
        self.init(Double(x), Double(-z))
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }

    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    /// Positive when `o` is counter-clockwise (to the left) of `self`.
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public var length: Double { (x * x + y * y).squareRoot() }
    public func distance(to o: Vec2) -> Double { (self - o).length }

    public var normalized: Vec2 {
        let l = length
        return l > 1e-9 ? Vec2(x / l, y / l) : .zero
    }
}

/// Wrap an angle in degrees to -180..180.
public func wrapDegrees(_ a: Double) -> Double {
    var r = (a + 180).truncatingRemainder(dividingBy: 360)
    if r < 0 { r += 360 }
    return r - 180
}

/// Signed angle in degrees from direction `from` to direction `to`. Positive = left.
public func signedAngle(from: Vec2, to: Vec2) -> Double {
    atan2(from.cross(to), from.dot(to)) * 180 / .pi
}

/// Closest point on segment a-b to p, and how far along the segment it is (0...1).
public func closestPointOnSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> (point: Vec2, t: Double) {
    let ab = b - a
    let len2 = ab.dot(ab)
    if len2 < 1e-12 { return (a, 0) }
    let t = min(max((p - a).dot(ab) / len2, 0), 1)
    return (a + ab * t, t)
}

public func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
    p.distance(to: closestPointOnSegment(p, a, b).point)
}
