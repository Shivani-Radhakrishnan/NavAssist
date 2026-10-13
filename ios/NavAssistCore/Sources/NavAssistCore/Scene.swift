import Foundation

// MARK: - Turning a depth network's relative output into meters

/// Depth Anything predicts *relative* inverse depth: bigger = closer, but with an unknown
/// scale and offset that change every frame. ARKit, even without LiDAR, tracks a few hundred
/// feature points with real 3-D positions. Where those points land in the picture we know
/// both the network's value and the true distance, so we can solve
///     networkValue = a * (1 / meters) + b
/// and then convert every pixel to meters.
public struct InverseDepthFit: Equatable, Sendable {
    public var a: Double
    public var b: Double
    /// How well the line fits the points it kept (1 = perfectly).
    public var r2: Double
    public var pointsUsed: Int

    /// Meters for a network value; nil when the value is beyond the fitted range (sky, far away).
    public func meters(_ value: Double) -> Double? {
        let inv = (value - b) / a
        guard inv > 1.0 / 20.0 else { return nil }     // farther than 20 m: ignore
        return 1 / inv
    }

    /// Robust least squares: fit, drop the worst 25% of points (ARKit outliers, edges where
    /// the network blurs depth), fit again. Nil if there are too few points or the fit is poor.
    public static func fit(networkValues r: [Double], meters d: [Double],
                           minPoints: Int = 12, minR2: Double = 0.5) -> InverseDepthFit? {
        var pairs = zip(r, d).filter { $0.1 > 0.2 && $0.1 < 15 && $0.0.isFinite }.map { (x: 1 / $0.1, y: $0.0) }
        guard pairs.count >= minPoints else { return nil }
        func solve(_ p: [(x: Double, y: Double)]) -> (a: Double, b: Double)? {
            let n = Double(p.count)
            let sx = p.reduce(0) { $0 + $1.x }, sy = p.reduce(0) { $0 + $1.y }
            let sxx = p.reduce(0) { $0 + $1.x * $1.x }, sxy = p.reduce(0) { $0 + $1.x * $1.y }
            let den = n * sxx - sx * sx
            guard abs(den) > 1e-12 else { return nil }
            let a = (n * sxy - sx * sy) / den
            return (a, (sy - a * sx) / n)
        }
        guard var (a, b) = solve(pairs) else { return nil }
        for _ in 0..<2 {
            pairs.sort { abs($0.y - (a * $0.x + b)) < abs($1.y - (a * $1.x + b)) }
            pairs = Array(pairs.prefix(max(minPoints, Int(Double(pairs.count) * 0.75))))
            guard let s = solve(pairs) else { return nil }
            (a, b) = s
        }
        guard a > 0 else { return nil }                // closer must mean bigger
        let mean = pairs.reduce(0) { $0 + $1.y } / Double(pairs.count)
        let ssTot = pairs.reduce(0) { $0 + ($1.y - mean) * ($1.y - mean) }
        let ssRes = pairs.reduce(0) { $0 + pow($1.y - (a * $1.x + b), 2) }
        let r2 = ssTot > 0 ? 1 - ssRes / ssTot : 0
        guard r2 >= minR2 else { return nil }
        return InverseDepthFit(a: a, b: b, r2: r2, pointsUsed: pairs.count)
    }
}

// MARK: - Stairs and drop-offs ahead

public struct StairCue: Equatable, Sendable {
    public enum Direction: String, Sendable { case up, down }
    public var direction: Direction
    /// Meters ahead to the first step.
    public var distance: Double
}

/// Looks at the ground in the walking corridor, in 25 cm slices ahead of the user.
/// The lowest points in each slice are the walking surface:
///   - the surface dropping 15 cm or more below the floor = stairs down / a drop-off;
///   - the surface rising in steps of 10-25 cm over at least two slices = stairs up.
/// A wall doesn't look like stairs up: its lowest points are still at floor level.
public struct StairDetector: Sendable {
    public var corridorHalfWidth = 0.45
    public var sliceDepth = 0.25
    public var range = 0.4...3.5
    public var minPointsPerSlice = 6

    public init() {}

    public func detect(_ points: [ObstaclePoint]) -> StairCue? {
        let nSlices = Int((range.upperBound - range.lowerBound) / sliceDepth)
        var slices = [[Double]](repeating: [], count: nSlices)
        for p in points where abs(p.lateral) <= corridorHalfWidth && range.contains(p.forward) {
            let i = min(Int((p.forward - range.lowerBound) / sliceDepth), nSlices - 1)
            slices[i].append(p.height)
        }
        // Walking surface per slice (20th percentile of heights), nil where too few points.
        let surface: [Double?] = slices.map { $0.count >= minPointsPerSlice ? percentile($0, 0.2) : nil }
        func distance(_ i: Int) -> Double { range.lowerBound + (Double(i) + 0.5) * sliceDepth }

        // Need flat floor first, so a phone tilted at the floor doesn't look like a drop.
        guard let firstFlat = surface.firstIndex(where: { $0.map { abs($0) < 0.08 } ?? false }) else { return nil }
        var i = firstFlat + 1
        while i < nSlices {
            guard let h = surface[i] else { i += 1; continue }
            // Down: this slice and the next measured one are both well below the floor.
            if h <= -0.15 {
                let next = surface[(i + 1)...].compactMap { $0 }.first
                if next == nil || next! <= -0.1 { return StairCue(direction: .down, distance: distance(i)) }
            }
            // Up: two consecutive rises of a step's height.
            if h >= 0.1, h <= 0.3, i + 1 < nSlices, let h2 = surface[i + 1], h2 - h >= 0.08, h2 - h <= 0.3 {
                return StairCue(direction: .up, distance: distance(i))
            }
            i += 1
        }
        return nil
    }
}

/// What the camera recognises about the scene, beyond raw obstacles.
public struct SceneHints: Equatable, Sendable {
    /// Meters to a door in the walking direction, if one is seen.
    public var doorAhead: Double?
    /// Which side of that door its handle is on, when the detector sees it.
    public var handleSide: Side?
    public var stairs: StairCue?
    /// Stairs are in view (from the detector, or Apple's image classifier as a fallback).
    public var stairsInView = false
    /// Meters to where those stairs start, when the detector located them and depth is known.
    public var stairsAhead: Double?

    public init(doorAhead: Double? = nil, handleSide: Side? = nil, stairs: StairCue? = nil,
                stairsInView: Bool = false, stairsAhead: Double? = nil) {
        self.doorAhead = doorAhead
        self.handleSide = handleSide
        self.stairs = stairs
        self.stairsInView = stairsInView
        self.stairsAhead = stairsAhead
    }
}
