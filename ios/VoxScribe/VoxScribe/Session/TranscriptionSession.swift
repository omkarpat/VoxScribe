import Foundation
import Observation

enum SegmentState: Sendable, Equatable {
    case rawFinal
    case corrected
}

struct TranscriptSegment: Sendable, Equatable, Identifiable {
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

    private let vocabulary: SessionVocabulary
    private let serverClient: ServerClient
    private let audioCapture: AudioCapture
    private let streamingClient: StreamingClient

    private var sessionId: String?
    private var pumpTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    init(
        vocabulary: SessionVocabulary,
        serverClient: ServerClient? = nil,
        audioCapture: AudioCapture? = nil,
        streamingClient: StreamingClient? = nil
    ) {
        self.vocabulary = vocabulary
        self.serverClient = serverClient ?? ServerClient()
        self.audioCapture = audioCapture ?? AudioCapture()
        self.streamingClient = streamingClient ?? StreamingClient()
    }

    func start() async {
        guard phase == .idle || phase == .stopped else { return }
        phase = .starting
        segments = []
        partial = ""

        do {
            async let tokenFuture = serverClient.fetchToken()
            async let audioStreamFuture = audioCapture.start()
            let token = try await tokenFuture
            let audioStream = try await audioStreamFuture
            let messages = try streamingClient.open(token: token, vocabulary: vocabulary)

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
                for await chunk in audioStream {
                    if Task.isCancelled { break }
                    do {
                        try await streamingClient.send(chunk)
                    } catch {
                        await self?.failSession(.classify(error))
                        break
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

        await streamingClient.close()
        receiveTask?.cancel()
        receiveTask = nil

        partial = ""
        phase = .stopped
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
            if turn.endOfTurn {
                commitFinal(turn)
            } else {
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
        let vocab = vocabulary
        let input = TurnInput(turnOrder: turn.turnOrder, transcript: trimmed)
        let client = serverClient

        Task { [weak self] in
            do {
                let corrected = try await client.correct(
                    sessionId: sessionId,
                    vocabulary: vocab,
                    turns: [input]
                )
                self?.applyCorrection(corrected)
            } catch {
                // Correction errors silently preserve the raw-final text.
            }
        }
    }

    private func applyCorrection(_ corrected: [Segment]) {
        for seg in corrected {
            guard let idx = segments.firstIndex(where: { $0.id == seg.id }) else { continue }
            segments[idx].text = seg.text
            segments[idx].state = .corrected
            segments[idx].sourceTurnOrders = seg.sourceTurnOrders
        }
    }

    private func failSession(_ error: SessionError) async {
        audioCapture.stop()
        pumpTask?.cancel()
        pumpTask = nil
        await streamingClient.close()
        receiveTask?.cancel()
        receiveTask = nil
        phase = .failed(error)
    }
}
