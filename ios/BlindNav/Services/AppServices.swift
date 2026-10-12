import BlindNavCore
import Foundation
import Observation

/// User preferences, saved between launches.
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var acceptedSafetyNotice: Bool { didSet { defaults.set(acceptedSafetyNotice, forKey: "acceptedSafetyNotice") } }
    var unit: DistanceUnit { didSet { defaults.set(unit.rawValue, forKey: "unit") } }
    var stepLength: Double { didSet { defaults.set(stepLength, forKey: "stepLength") } }
    var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    var obstacleWarnings: Bool { didSet { defaults.set(obstacleWarnings, forKey: "obstacleWarnings") } }
    var warnDistance: Double { didSet { defaults.set(warnDistance, forKey: "warnDistance") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }

    init() {
        defaults.register(defaults: [
            "unit": DistanceUnit.meters.rawValue, "stepLength": 0.7, "speechRate": 0.5,
            "obstacleWarnings": true, "warnDistance": 1.5, "haptics": true,
        ])
        acceptedSafetyNotice = defaults.bool(forKey: "acceptedSafetyNotice")
        unit = DistanceUnit(rawValue: defaults.string(forKey: "unit") ?? "") ?? .meters
        stepLength = defaults.double(forKey: "stepLength")
        speechRate = defaults.double(forKey: "speechRate")
        obstacleWarnings = defaults.bool(forKey: "obstacleWarnings")
        warnDistance = defaults.double(forKey: "warnDistance")
        haptics = defaults.bool(forKey: "haptics")
    }

    var phrasing: Phrasing { Phrasing(unit: unit, stepLength: stepLength) }

    var guidance: GuidanceSettings {
        var g = GuidanceSettings()
        g.phrasing = phrasing
        return g
    }
}

/// Everything the screens share. One AR session for the whole app.
@Observable
final class AppServices {
    let settings = AppSettings()
    let ar = ARController()
    let speaker = Speaker()
    let haptics = Haptics()
    let store = PlaceStore()
    /// Last sentence spoken, shown as a caption for sighted helpers and low-vision users.
    private(set) var caption = ""

    init() {
        speaker.onSpeak = { [weak self] text in self?.caption = text }
        applySettings()
        if !ARController.hasLiDAR {
            DispatchQueue.global(qos: .utility).async { _ = NeuralObstacleSource.sharedModel }
        }
    }

    func applySettings() {
        // Settings' 0...1 slider mapped onto a comfortable range of speech speeds.
        speaker.rate = Float(0.35 + settings.speechRate * 0.3)
        haptics.enabled = settings.haptics
    }

    func handle(_ events: [GuidanceEvent]) {
        for e in events {
            switch e {
            case .speak(let text, let urgent): speaker.say(text, urgent: urgent)
            case .haptic(let cue): haptics.play(cue)
            case .arrived, .offRoute: break
            }
        }
    }
}
