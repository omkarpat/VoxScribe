@preconcurrency import AVFoundation
import Foundation
import Speech

enum LocalSpeechRecognizerError: Error {
    case notAuthorized
    case unavailable
}

@MainActor
final class LocalSpeechRecognizer {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<String>.Continuation?
    private var broken = false

    let partials: AsyncStream<String>

    init() {
        var cont: AsyncStream<String>.Continuation!
        self.partials = AsyncStream<String>(bufferingPolicy: .unbounded) { c in cont = c }
        self.continuation = cont
    }

    func start() async throws {
        let status = await Self.requestAuthorization()
        print("[LocalSFSR] auth status=\(status.rawValue)")
        guard status == .authorized else { throw LocalSpeechRecognizerError.notAuthorized }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), r.isAvailable else {
            print("[LocalSFSR] recognizer unavailable (nil or !available)")
            throw LocalSpeechRecognizerError.unavailable
        }
        print("[LocalSFSR] ready available=\(r.isAvailable) supportsOnDevice=\(r.supportsOnDeviceRecognition)")
        self.recognizer = r
        try beginTask()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if broken { return }
        request?.append(buffer)
    }

    // Ends the current recognition task and starts a fresh one so the running
    // transcription resets between AAI turn boundaries.
    func reset() {
        if broken { return }
        finishCurrentTask()
        continuation?.yield("")
        try? beginTask()
    }

    func stop() {
        finishCurrentTask()
        continuation?.finish()
        continuation = nil
    }

    private func beginTask() throws {
        guard let recognizer else { throw LocalSpeechRecognizerError.unavailable }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Leave on-device off: on the simulator (and older devices) the
        // on-device model isn't downloaded by default and the recognizer
        // will stay silent. Remote recognition still gives us fast partials.
        self.request = req
        print("[LocalSFSR] beginTask")
        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let error {
                print("[LocalSFSR] error: \(error)")
                Task { @MainActor in self?.markBroken() }
            }
            if let result {
                let text = result.bestTranscription.formattedString
                print("[LocalSFSR] partial len=\(text.count) final=\(result.isFinal) text=\"\(text)\"")
                Task { @MainActor in self?.continuation?.yield(text) }
            }
        }
    }

    private func markBroken() {
        guard !broken else { return }
        broken = true
        finishCurrentTask()
        continuation?.finish()
        continuation = nil
    }

    private func finishCurrentTask() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
    }
}
