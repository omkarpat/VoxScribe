import Foundation

struct TurnInput: Codable, Sendable, Equatable {
    let turnOrder: Int
    let transcript: String
}

struct Segment: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let sourceTurnOrders: [Int]
    let text: String
}

enum ServerClientError: Error, Equatable {
    case httpStatus(Int)
    case invalidResponse
    case timeout
    case transport(String)
    case decoding(String)
}

struct ServerClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let correctionTimeout: TimeInterval

    init(
        baseURL: URL = AppConfig.serverBaseURL,
        session: URLSession = .shared,
        correctionTimeout: TimeInterval = 3.0
    ) {
        self.baseURL = baseURL
        self.session = session
        self.correctionTimeout = correctionTimeout
    }

    // MARK: - /token

    func fetchToken() async throws -> String {
        let url = baseURL.appendingPathComponent("token")
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, response) = try await send(req)
        try ensureOK(response)
        struct Body: Decodable { let token: String }
        do {
            return try JSONDecoder().decode(Body.self, from: data).token
        } catch {
            throw ServerClientError.decoding(String(describing: error))
        }
    }

    // MARK: - /correct

    func correct(
        sessionId: String,
        vocabulary: SessionVocabulary,
        turns: [TurnInput]
    ) async throws -> [Segment] {
        struct Body: Encodable {
            let sessionId: String
            let vocabularyRevision: Int
            let protectedTerms: [String]
            let turns: [TurnInput]
        }

        let payload = Body(
            sessionId: sessionId,
            vocabularyRevision: vocabulary.revision,
            protectedTerms: vocabulary.protectedTerms,
            turns: turns
        )

        var req = URLRequest(url: baseURL.appendingPathComponent("correct"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = correctionTimeout

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try encoder.encode(payload)

        let (data, response) = try await send(req)
        try ensureOK(response)

        struct Response: Decodable { let segments: [Segment] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Response.self, from: data).segments
        } catch {
            throw ServerClientError.decoding(String(describing: error))
        }
    }

    // MARK: - internals

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw ServerClientError.timeout
        } catch {
            throw ServerClientError.transport(String(describing: error))
        }
    }

    private func ensureOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ServerClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ServerClientError.httpStatus(http.statusCode)
        }
    }
}
