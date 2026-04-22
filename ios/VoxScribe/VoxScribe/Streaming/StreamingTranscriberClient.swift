import Foundation

struct BeginMessage: Sendable, Equatable {
    let id: String
    let expiresAt: Int?
}

struct TurnMessage: Sendable, Equatable {
    let turnOrder: Int
    let transcript: String
    let endOfTurn: Bool
    let languageCode: String?
}

enum ServerMessage: Sendable, Equatable {
    case begin(BeginMessage)
    case turn(TurnMessage)
    case termination
}

enum StreamingClientError: Error {
    case invalidURL
    case notConnected
    case transport(String)
    case decoding(String)
    case closedByServer(code: Int, reason: String?)
}

// Provider-neutral surface used by TranscriptionSession. Any ASR provider
// that issues a short-lived token + WebSocket URL can back this protocol —
// VoxScribe only needs a stream of Begin/Turn/Termination events and a way
// to send 16 kHz Int16 PCM frames.
@MainActor
protocol StreamingTranscriberClient: AnyObject {
    func open(wsURL: URL, sampleRate: Int) throws -> AsyncStream<ServerMessage>
    func send(_ audio: Data) async throws
    func close(terminateTimeout: TimeInterval) async
}
