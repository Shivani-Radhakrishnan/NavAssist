import Foundation

/// One object found by the door / door-handle / stairs detector (a Core ML model trained on
/// Open Images; see training/detector). Boxes are normalised to the upright camera image,
/// origin at the top left.
public struct Detection: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case door
        case doorHandle = "door handle"
        case stairs
    }

    public var kind: Kind
    public var confidence: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(kind: Kind, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.kind = kind
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    func contains(_ px: Double, _ py: Double, margin: Double) -> Bool {
        let mx = width * margin, my = height * margin
        return px >= x - mx && px <= maxX + mx && py >= y - my && py <= maxY + my
    }
}

/// Which side of a door its handle is on, from the user's point of view.
public enum Side: String, Equatable, Sendable {
    case left, right
}

/// Turns detector boxes into scene hints: a door in the walking direction and how far it
/// is, which side its handle is on, and stairs ahead with a distance.
///
/// `depth(u, v)` gives meters to the surface at a normalised image point (from LiDAR, the
/// neural depth estimate or an ARKit raycast), or nil when unknown.
public struct DetectionInterpreter: Sendable {
    public var minConfidence: [Detection.Kind: Double] = [.door: 0.5, .doorHandle: 0.35, .stairs: 0.5]
    /// The horizontal band of the image counted as "ahead" (the walking corridor).
    public var corridor: ClosedRange<Double> = 0.3...0.7
    public var maxRange = 6.0

    public init() {}

    public func hints(from detections: [Detection], depth: (Double, Double) -> Double?) -> SceneHints {
        let kept = detections.filter { $0.confidence >= (minConfidence[$0.kind] ?? 0.5) }
        let ahead = kept.filter { $0.x < corridor.upperBound && $0.maxX > corridor.lowerBound }
        var hints = SceneHints()

        // Door: the nearest one in the corridor (or the biggest, when depth is unknown).
        let doors = ahead.filter { $0.kind == .door }.map { ($0, depth($0.centerX, $0.centerY)) }
        let door = doors.min { a, b in
            switch (a.1, b.1) {
            case let (da?, db?): return da < db
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.0.width * a.0.height > b.0.width * b.0.height
            }
        }
        if let (box, meters) = door {
            if let m = meters, m <= maxRange { hints.doorAhead = m }
            let handles = kept.filter { $0.kind == .doorHandle && box.contains($0.centerX, $0.centerY, margin: 0.1) }
            if let handle = handles.max(by: { $0.confidence < $1.confidence }) {
                hints.handleSide = handle.centerX < box.centerX ? .left : .right
            }
        }

        // Stairs: distance where the stairs start, i.e. the bottom edge of the box.
        let stairs = ahead.filter { $0.kind == .stairs }
        if !stairs.isEmpty {
            hints.stairsInView = true
            let near = stairs.compactMap { depth($0.centerX, min($0.maxY - 0.05 * $0.height, 0.99)) }
                .filter { $0 <= maxRange }.min()
            hints.stairsAhead = near
        }
        return hints
    }
}
