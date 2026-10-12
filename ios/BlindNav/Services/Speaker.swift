import AVFoundation
import UIKit

/// Speaks guidance. Urgent messages (turns, "Stop") cut in immediately; others wait
/// for the current sentence, and only the newest waiting one is kept so the app never
/// falls behind reading out stale directions.
// Only used from the main thread; delegate callbacks hop back to main before touching state.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private var pending: String?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Called with every sentence spoken, for the on-screen caption.
    var onSpeak: ((String) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String, urgent: Bool = false) {
        if urgent {
            pending = nil
            synth.stopSpeaking(at: .immediate)
            speakNow(text)
        } else if synth.isSpeaking {
            pending = text
        } else {
            speakNow(text)
        }
    }

    func stop() {
        pending = nil
        synth.stopSpeaking(at: .immediate)
    }

    private func speakNow(_ text: String) {
        onSpeak?(text)
        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        u.prefersAssistiveTechnologySettings = true   // use the user's VoiceOver voice if set
        // Duck music/podcasts only while a sentence is being spoken. Set every time, because
        // listening for a voice command switches the audio session to recording.
        let audio = AVAudioSession.sharedInstance()
        if audio.category != .playback {
            try? audio.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        }
        try? audio.setActive(true)
        synth.speak(u)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speakPendingOrRelease() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speakPendingOrRelease() }
    }

    private func speakPendingOrRelease() {
        guard !synth.isSpeaking else { return }
        if let next = pending {
            pending = nil
            speakNow(next)
        } else {
            // Let other apps' audio return to full volume.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
