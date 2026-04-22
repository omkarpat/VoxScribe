import Foundation

@MainActor
final class AssemblyAIStreamingClient: StreamingTranscriberClient {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var readerTask: Task<Void, Never>?
    private var continuation: AsyncStream<ServerMessage>.Continuation?
    private var terminationContinuation: CheckedContinuation<Void, Never>?
    private var isClosing = false

    init(session: URLSession = .shared) {
        self.session = session
    }

    func open(wsURL: URL, sampleRate: Int = 16000) throws -> AsyncStream<ServerMessage> {
        precondition(task == nil, "AssemblyAIStreamingClient.open() called while already open")

        let wsTask = session.webSocketTask(with: wsURL)
        task = wsTask

        let (stream, cont) = AsyncStream<ServerMessage>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont

        wsTask.resume()
        readerTask = Task { [weak self] in
            await self?.readLoop(task: wsTask)
        }
        return stream
    }

    func send(_ audio: Data) async throws {
        guard let task else { throw StreamingClientError.notConnected }
        do {
            try await task.send(.data(audio))
        } catch {
            throw StreamingClientError.transport(String(describing: error))
        }
    }

    func close(terminateTimeout: TimeInterval = 2.0) async {
        guard let task, !isClosing else { return }
        isClosing = true

        let terminate = Data(#"{"type":"Terminate"}"#.utf8)
        try? await task.send(.data(terminate))

        await withCheckedContinuation { cont in
            self.terminationContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(terminateTimeout * 1_000_000_000))
                guard let self, let pending = self.terminationContinuation else { return }
                self.terminationContinuation = nil
                pending.resume()
            }
        }

        task.cancel(with: .normalClosure, reason: nil)
        readerTask?.cancel()
        readerTask = nil
        self.task = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - reader

    private func readLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                handle(message)
            } catch {
                if !isClosing {
                    let code = task.closeCode.rawValue
                    let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    print("[AssemblyAIStreamingClient] WS closed unexpectedly code=\(code) reason=\(reason) error=\(error)")
                    continuation?.finish()
                }
                break
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        guard let parsed = Self.decode(data) else { return }
        continuation?.yield(parsed)
        if case .termination = parsed {
            terminationContinuation?.resume()
            terminationContinuation = nil
        }
    }

    private static func decode(_ data: Data) -> ServerMessage? {
        struct Envelope: Decodable { let type: String }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
        switch env.type {
        case "Begin":
            struct Payload: Decodable { let id: String; let expiresAt: Int? }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .begin(BeginMessage(id: p.id, expiresAt: p.expiresAt))
        case "Turn":
            struct Payload: Decodable {
                let turnOrder: Int
                let transcript: String
                let endOfTurn: Bool
                let languageCode: String?
            }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
            print("[AssemblyAIStreamingClient] Turn t=\(stamp) order=\(p.turnOrder) eot=\(p.endOfTurn) lang=\(p.languageCode ?? "-") len=\(p.transcript.count) text=\"\(p.transcript)\"")
            return .turn(TurnMessage(
                turnOrder: p.turnOrder,
                transcript: p.transcript,
                endOfTurn: p.endOfTurn,
                languageCode: p.languageCode
            ))
        case "Termination":
            return .termination
        case "Error":
            struct Payload: Decodable { let errorCode: Int?; let error: String? }
            if let p = try? decoder.decode(Payload.self, from: data) {
                print("[AssemblyAIStreamingClient] AAI error code=\(p.errorCode ?? -1) message=\(p.error ?? "?")")
            } else if let raw = String(data: data, encoding: .utf8) {
                print("[AssemblyAIStreamingClient] AAI error (raw): \(raw)")
            }
            return nil
        default:
            return nil
        }
    }
}
