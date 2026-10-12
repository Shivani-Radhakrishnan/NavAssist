import AVFoundation
import AudioToolbox
import Speech

/// Listens for one spoken command after the user taps the screen. Recognition runs on
/// the phone when the device supports it. Stops on its own after a short pause.
final class VoiceListener {
    enum Failure: Error {
        case notAllowed, unavailable
    }

    private(set) var isListening = false
    /// Words recognised so far, for the on-screen caption.
    var onPartial: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var maxTimer: Timer?
    private var latest = ""
    private var completion: ((Result<String, Failure>) -> Void)?

    /// Ask for microphone and speech-recognition permission (only asks the first time).
    func requestPermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { mic in
                DispatchQueue.main.async { done(status == .authorized && mic) }
            }
        }
    }

    func listen(_ done: @escaping (Result<String, Failure>) -> Void) {
        guard !isListening else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioApplication.shared.recordPermission == .granted else {
            done(.failure(.notAllowed))
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            done(.failure(.unavailable))
            return
        }
        completion = done
        latest = ""

        AudioSession.shared.use("listen", true)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = ["save this place as", "take me to", "navigate to", "where am I",
                                 "what's around", "record location", "stop", "repeat"]
        request = req

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            finish(failure: .unavailable)
            return
        }
        isListening = true
        AudioServicesPlaySystemSound(1113)   // "begin listening" tone

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                if let result {
                    self.latest = result.bestTranscription.formattedString
                    self.onPartial?(self.latest)
                    self.restartSilenceTimer()
                    if result.isFinal { self.finish(failure: nil) }
                } else if error != nil {
                    // Nothing recognised yet means the recogniser failed, not that the user was silent.
                    self.finish(failure: self.latest.isEmpty ? .unavailable : nil)
                }
            }
        }
        // Give up if nothing is said; never listen for more than 8 seconds.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.finish(failure: nil) }
        maxTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.finish(failure: nil) }
    }

    /// Stop listening now and use what was heard so far (or report a failure).
    func finish(failure: Failure? = nil) {
        guard isListening || completion != nil else { return }
        silenceTimer?.invalidate()
        maxTimer?.invalidate()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if isListening { AudioServicesPlaySystemSound(1114) }   // "done listening" tone
        isListening = false
        AudioSession.shared.use("listen", false)
        let done = completion
        completion = nil
        if let failure { done?(.failure(failure)) } else { done?(.success(latest)) }
    }

    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        // 1.3 s of quiet after some words = the user has finished the sentence.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in self?.finish(failure: nil) }
    }
}
