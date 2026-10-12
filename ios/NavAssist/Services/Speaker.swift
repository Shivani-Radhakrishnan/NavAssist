import AVFoundation
import NavAssistCore
import UIKit

/// One audio-session setup for the whole app. Speaking and listening both need it; switching
/// categories between them used to cut the microphone off mid-command. The session is only
/// active while something is speaking or listening, so other apps' audio returns to full
/// volume in between.
final class AudioSession {
    static let shared = AudioSession()
    private var users: Set<String> = []

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
    }

    func use(_ who: String, _ on: Bool) {
        let wasEmpty = users.isEmpty
        if on { users.insert(who) } else { users.remove(who) }
        if wasEmpty && !users.isEmpty {
            try? AVAudioSession.sharedInstance().setActive(true)
        } else if !wasEmpty && users.isEmpty {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Speaks guidance. What to say and when is decided by `SpeechArbiter` (NavAssistCore):
/// safety beats directions beats information, nothing interrupts a safety warning in its first
/// moments, waiting messages expire instead of piling up, and nothing is spoken while the user
/// is giving a voice command.
// Only used from the main thread; delegate callbacks hop back to main before touching state.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private var arbiter = SpeechArbiter()
    private var currentUtterance: AVSpeechUtterance?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Called with every sentence spoken, for the on-screen caption.
    var onSpeak: ((String) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
        _ = AudioSession.shared
    }

    private var now: Double { CACurrentMediaTime() }

    func say(_ text: String, priority: SpeechPriority = .navigation, urgent: Bool = false) {
        perform(arbiter.request(text, priority: priority, urgent: urgent, now: now))
    }

    /// The microphone is opening (true) or closed (false). Speech pauses while it's open.
    func setListening(_ on: Bool) {
        if on { silence() }
        perform(arbiter.setListening(on, now: now))
    }

    func stop() {
        arbiter.clear()
        silence()
        AudioSession.shared.use("speech", false)
    }

    private func perform(_ action: SpeechArbiter.Action) {
        switch action {
        case .none:
            if !arbiter.isSpeaking { AudioSession.shared.use("speech", false) }
        case .speak(let text):
            speakNow(text)
        case .interrupt(let text):
            silence()
            speakNow(text)
        }
    }

    /// Stop the current sentence without treating it as finished (the arbiter already decided).
    private func silence() {
        currentUtterance = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    private func speakNow(_ text: String) {
        onSpeak?(text)
        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        u.prefersAssistiveTechnologySettings = true   // use the user's VoiceOver voice if set
        currentUtterance = u
        AudioSession.shared.use("speech", true)
        synth.speak(u)
    }

    private func ended(_ u: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, u === self.currentUtterance else { return }   // a cancelled, replaced sentence
            self.currentUtterance = nil
            self.perform(self.arbiter.finished(now: self.now))
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { ended(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { ended(utterance) }
}
