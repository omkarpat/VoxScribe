import Foundation
import Observation

nonisolated enum SegmentState: String, Sendable, Codable, Equatable {
    case rawFinal
    case corrected
}

nonisolated struct TranscriptSegment: Sendable, Codable, Equatable, Identifiable {
    let id: String
    var text: String
    var state: SegmentState
    var sourceTurnOrders: [Int]
}

enum SessionError: Sendable, Equatable {
    case serverUnreachable
    case microphonePermissionDenied
    case microphoneUnavailable
    case unknown

    var userMessage: String {
        switch self {
        case .serverUnreachable:
            return "I'm having trouble connecting to the server. Please try again later."
        case .microphonePermissionDenied:
            return "Microphone access is off. Enable it in Settings to start recording."
        case .microphoneUnavailable:
            return "The microphone isn't available right now. Please try again."
        case .unknown:
            return "Something went wrong starting the session. Please try again."
        }
    }

    static func classify(_ error: Error) -> SessionError {
        if let audio = error as? AudioCaptureError {
            switch audio {
            case .permissionDenied: return .microphonePermissionDenied
            default: return .microphoneUnavailable
            }
        }
        if error is ServerClientError { return .serverUnreachable }
        if error is StreamingClientError { return .serverUnreachable }
        return .unknown
    }
}

enum SessionPhase: Sendable, Equatable {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed(SessionError)
}

@Observable
@MainActor
final class TranscriptionSession {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var partial: String = ""
    private(set) var phase: SessionPhase = .idle
    private(set) var startedAt: Date?

    private let vocabularyProvider: @MainActor () -> SessionVocabulary
    private let profileProvider: @MainActor () -> CorrectionMode
    private let localPartialsEnabledProvider: @MainActor () -> Bool
    private let serverClient: ServerClient
    private let audioCapture: AudioCapture
    private let streamingClient: any StreamingTranscriberClient
    private let localRecognizer: LocalSpeechRecognizer

    private var sessionId: String?
    private var lastDetectedLanguage: String?
    private var pumpTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var localPumpTask: Task<Void, Never>?
    private var localReceiveTask: Task<Void, Never>?
    private var localEnabled = false
    private var correctionTasks: [Task<Void, Never>] = []

    init(
        vocabulary: @escaping @MainActor () -> SessionVocabulary,
        profile: @escaping @MainActor () -> CorrectionMode,
        localPartialsEnabled: @escaping @MainActor () -> Bool,
        serverClient: ServerClient? = nil,
        audioCapture: AudioCapture? = nil,
        streamingClient: (any StreamingTranscriberClient)? = nil,
        localRecognizer: LocalSpeechRecognizer? = nil
    ) {
        self.vocabularyProvider = vocabulary
        self.profileProvider = profile
        self.localPartialsEnabledProvider = localPartialsEnabled
        self.serverClient = serverClient ?? ServerClient()
        self.audioCapture = audioCapture ?? AudioCapture()
        self.streamingClient = streamingClient ?? AssemblyAIStreamingClient()
        self.localRecognizer = localRecognizer ?? LocalSpeechRecognizer()
    }

    func start() async {
        guard phase == .idle || phase == .stopped else { return }
        phase = .starting
        segments = []
        partial = ""
        lastDetectedLanguage = nil

        // Snapshot vocabulary at session start for the ASR token. AAI can't
        // swap keyterms mid-stream. Mid-session edits still take effect on
        // /correct calls (which re-read the provider per turn).
        let startVocabulary = vocabularyProvider()

        do {
            async let credentialsFuture = serverClient.fetchSessionCredentials(vocabulary: startVocabulary)
            async let audioStreamsFuture = audioCapture.start()
            let credentials = try await credentialsFuture
            let audioStreams = try await audioStreamsFuture
            let messages = try streamingClient.open(wsURL: credentials.wsURL, sampleRate: credentials.sampleRate)

            // Local SFSR is best-effort and user-gated via Settings. If the
            // toggle is off, or auth fails, or the recognizer is unavailable,
            // we fall back to AAI-only partials.
            if localPartialsEnabledProvider() {
                do {
                    try await localRecognizer.start()
                    localEnabled = true
                    print("[TranscriptionSession] local recognizer enabled")
                } catch {
                    print("[TranscriptionSession] local recognizer disabled: \(error)")
                    localEnabled = false
                }
            } else {
                localEnabled = false
            }

            startedAt = Date()
            phase = .running

            receiveTask = Task { [weak self] in
                guard let self else { return }
                for await msg in messages {
                    await self.handleServerMessage(msg)
                }
                await self.handleStreamEnded()
            }

            pumpTask = Task { [weak self, streamingClient] in
                for await chunk in audioStreams.pcm {
                    if Task.isCancelled { break }
                    do {
                        try await streamingClient.send(chunk)
                    } catch {
                        await self?.failSession(.classify(error))
                        break
                    }
                }
            }

            if localEnabled {
                localPumpTask = Task { [weak self] in
                    for await buffer in audioStreams.buffers {
                        if Task.isCancelled { break }
                        self?.localRecognizer.append(buffer)
                    }
                }
                localReceiveTask = Task { [weak self] in
                    guard let self else { return }
                    for await text in self.localRecognizer.partials {
                        self.partial = text
                    }
                    // Stream ended before stop() — SFSR failed (simulator
                    // asset missing, remote cut out, etc.). Fall back to
                    // AAI partials for the rest of the session.
                    if case .running = self.phase {
                        print("[TranscriptionSession] local recognizer ended; falling back to AAI partials")
                        self.localEnabled = false
                    }
                }
            } else {
                // Drain the buffer stream so the tap doesn't block on an
                // unbounded backlog.
                localPumpTask = Task {
                    for await _ in audioStreams.buffers {
                        if Task.isCancelled { break }
                    }
                }
            }
        } catch {
            await failSession(.classify(error))
        }
    }

    func stop() async {
        guard phase == .running else { return }
        phase = .stopping

        audioCapture.stop()
        pumpTask?.cancel()
        pumpTask = nil
        localPumpTask?.cancel()
        localPumpTask = nil

        if localEnabled {
            localRecognizer.stop()
        }
        localReceiveTask?.cancel()
        localReceiveTask = nil

        await streamingClient.close(terminateTimeout: 2.0)
        receiveTask?.cancel()
        receiveTask = nil

        partial = ""
        phase = .stopped
    }

    // MARK: - export

    /// Awaits any in-flight correction tasks and returns a snapshot of the
    /// final transcript. Safe to call after `stop()` — the stop path cancels
    /// the network pumps but leaves correction tasks to complete naturally.
    func finalizeForExport() async -> FinalizedTranscript {
        let pending = correctionTasks
        correctionTasks.removeAll()
        for task in pending {
            _ = await task.value
        }
        let endedAt = Date()
        let startedAt = self.startedAt ?? endedAt
        let rendered = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return FinalizedTranscript(
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            mode: profileProvider(),
            transcriber: vocabularyProvider().transcriber,
            segments: segments,
            renderedText: rendered
        )
    }

    // MARK: - message handling

    private func handleStreamEnded() async {
        guard phase == .running else { return }
        await failSession(.serverUnreachable)
    }

    private func handleServerMessage(_ msg: ServerMessage) async {
        switch msg {
        case .begin(let begin):
            sessionId = begin.id
        case .turn(let turn):
            if let lang = turn.languageCode, !lang.isEmpty {
                lastDetectedLanguage = lang
            }
            if turn.endOfTurn {
                commitFinal(turn)
                if localEnabled { localRecognizer.reset() }
            } else if !localEnabled {
                partial = turn.transcript
            }
        case .termination:
            break
        }
    }

    private func commitFinal(_ turn: TurnMessage) {
        partial = ""
        let trimmed = turn.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let id = "turn-\(turn.turnOrder)"
        let segment = TranscriptSegment(
            id: id,
            text: trimmed,
            state: .rawFinal,
            sourceTurnOrders: [turn.turnOrder]
        )
        segments.append(segment)

        guard let sessionId else { return }
        let vocab = vocabularyProvider()
        let mode = profileProvider()
        let detectedLanguage = lastDetectedLanguage
        let input = TurnInput(turnOrder: turn.turnOrder, transcript: trimmed)
        let client = serverClient

        let task = Task { [weak self] in
            do {
                let corrected: [Segment]
                if mode.usesCodeEndpoint {
                    corrected = try await client.correctCode(
                        sessionId: sessionId,
                        vocabulary: vocab,
                        turns: [input]
                    )
                } else {
                    corrected = try await client.correct(
                        sessionId: sessionId,
                        vocabulary: vocab,
                        profile: mode.serverProfile ?? "default",
                        detectedLanguage: detectedLanguage,
                        turns: [input]
                    )
                }
                self?.applyCorrection(corrected)
            } catch {
                // Correction errors silently preserve the raw-final text.
            }
        }
        correctionTasks.append(task)
    }

    private func applyCorrection(_ corrected: [Segment]) {
        for seg in corrected {
            guard let idx = segments.firstIndex(where: { $0.id == seg.id }) else { continue }
            if seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Correction judged the turn to be pure disfluency — drop it
                // instead of leaving a blank row in the transcript.
                segments.remove(at: idx)
                continue
            }
            segments[idx].text = seg.text
            segments[idx].state = .corrected
            segments[idx].sourceTurnOrders = seg.sourceTurnOrders
        }
    }

    private func failSession(_ error: SessionError) async {
        audioCapture.stop()
        pumpTask?.cancel()
        pumpTask = nil
        localPumpTask?.cancel()
        localPumpTask = nil
        if localEnabled { localRecognizer.stop() }
        localReceiveTask?.cancel()
        localReceiveTask = nil
        await streamingClient.close(terminateTimeout: 2.0)
        receiveTask?.cancel()
        receiveTask = nil
        phase = .failed(error)
    }
}
