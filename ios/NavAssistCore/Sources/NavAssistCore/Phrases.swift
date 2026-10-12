import Foundation

/// How distances are spoken.
public enum DistanceUnit: String, Codable, CaseIterable, Sendable {
    case meters, feet, steps
}

public struct Phrasing: Codable, Equatable, Sendable {
    public var unit: DistanceUnit
    /// Used when `unit == .steps`. An average adult step is about 0.7 m.
    public var stepLength: Double

    public init(unit: DistanceUnit = .meters, stepLength: Double = 0.7) {
        self.unit = unit
        self.stepLength = stepLength
    }

    public func distance(_ meters: Double) -> String {
        switch unit {
        case .meters:
            let v = meters < 10 ? (meters * 2).rounded() / 2 : meters.rounded()
            if v <= 0.5 { return "half a meter" }
            if v == 1 { return "1 meter" }
            return v == v.rounded() ? "\(Int(v)) meters" : String(format: "%.1f meters", v)
        case .feet:
            let f = max(1, Int((meters * 3.28084).rounded()))
            return f == 1 ? "1 foot" : "\(f) feet"
        case .steps:
            let s = max(1, Int((meters / stepLength).rounded()))
            return s == 1 ? "1 step" : "\(s) steps"
        }
    }
}

/// Clock-face direction for a relative angle (positive = left). 12 is straight ahead.
public func clockDirection(_ relativeDegrees: Double) -> Int {
    let hour = Int((12 - relativeDegrees / 30).rounded()) % 12
    return hour <= 0 ? hour + 12 : hour
}

/// Words for a change of direction between two legs of a route (positive = left).
public func turnWords(_ turnDegrees: Double) -> String {
    let side = turnDegrees > 0 ? "left" : "right"
    switch abs(turnDegrees) {
    case ..<20: return "Continue straight"
    case ..<45: return "Bear slightly \(side)"
    case ..<120: return "Turn \(side)"
    case ..<155: return "Turn sharply \(side)"
    default: return "Turn around"
    }
}

/// "Turn to 3 o'clock" style prompt used when the user is facing the wrong way.
public func headingPrompt(_ relativeDegrees: Double) -> String {
    let h = clockDirection(relativeDegrees)
    if h == 6 { return "Turn around" }
    return "Turn to \(h) o'clock"
}
