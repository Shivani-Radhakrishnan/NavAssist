import NavAssistCore
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
    /// Predictive cues for hesitation and early turns.
    var adaptiveCues: Bool { didSet { defaults.set(adaptiveCues, forKey: "adaptiveCues") } }
    /// Study mode: predictive cues alternate on/off between trips, for a fair comparison.
    var studyMode: Bool { didSet { defaults.set(studyMode, forKey: "studyMode") } }
    var participant: String { didSet { defaults.set(participant, forKey: "participant") } }

    init() {
        defaults.register(defaults: [
            "unit": DistanceUnit.meters.rawValue, "stepLength": 0.7, "speechRate": 0.5,
            "obstacleWarnings": true, "warnDistance": 1.5, "haptics": true,
            "adaptiveCues": true, "studyMode": false, "participant": "P1",
        ])
        acceptedSafetyNotice = defaults.bool(forKey: "acceptedSafetyNotice")
        unit = DistanceUnit(rawValue: defaults.string(forKey: "unit") ?? "") ?? .meters
        stepLength = defaults.double(forKey: "stepLength")
        speechRate = defaults.double(forKey: "speechRate")
        obstacleWarnings = defaults.bool(forKey: "obstacleWarnings")
        warnDistance = defaults.double(forKey: "warnDistance")
        haptics = defaults.bool(forKey: "haptics")
        adaptiveCues = defaults.bool(forKey: "adaptiveCues")
        studyMode = defaults.bool(forKey: "studyMode")
        participant = defaults.string(forKey: "participant") ?? "P1"
    }

    /// Whether the next trip gets predictive cues. In study mode trips alternate, and the
    /// starting condition alternates between participants (P1 starts with cues, P2 without...).
    func nextTripIsAdaptive() -> Bool {
        guard studyMode else { return adaptiveCues }
        // Counted per participant, so one person's odd number of trips can't flip the next person's order.
        let key = "tripCounter." + participant
        let count = defaults.integer(forKey: key)
        let digits = Int(participant.filter(\.isNumber)) ?? 1
        defaults.set(count + 1, forKey: key)
        return (count + digits) % 2 == 1
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
    let trips = TripStore()
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
