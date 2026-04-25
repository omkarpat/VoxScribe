import Foundation

nonisolated struct OneDriveUploadResult: Equatable, Sendable {
    let fileName: String
    let webURL: URL?
    let uploadedAt: Date
}

nonisolated enum OneDriveUploadError: Error, Equatable {
    case notConnected
    case connectionExpired
    case transport(String)
    case graphStatus(code: Int, body: String)
    case malformed(String)
}

nonisolated struct OneDriveUploader: Sendable {
    private let tokenRefresher: MicrosoftTokenRefresher
    private let urlSession: URLSession

    init(
        tokenRefresher: MicrosoftTokenRefresher,
        urlSession: URLSession = .shared
    ) {
        self.tokenRefresher = tokenRefresher
        self.urlSession = urlSession
    }

    func upload(_ transcript: FinalizedTranscript) async throws -> OneDriveUploadResult {
        let filename = Self.filename(for: transcript.endedAt)
        let body = Self.renderFileBody(transcript)
        let bodyData = Data(body.utf8)

        let token = try await validAccessToken(forceRefresh: false)
        do {
            return try await putToGraph(filename: filename, body: bodyData, accessToken: token)
        } catch OneDriveUploadError.graphStatus(let code, _) where code == 401 {
            let refreshed = try await validAccessToken(forceRefresh: true)
            return try await putToGraph(filename: filename, body: bodyData, accessToken: refreshed)
        }
    }

    private func validAccessToken(forceRefresh: Bool) async throws -> String {
        do {
            return try await tokenRefresher.validAccessToken(forceRefresh: forceRefresh)
        } catch MicrosoftTokenRefreshError.notConnected {
            throw OneDriveUploadError.notConnected
        } catch MicrosoftTokenRefreshError.terminalAuthFailure {
            throw OneDriveUploadError.connectionExpired
        } catch MicrosoftTokenRefreshError.transport(let message) {
            throw OneDriveUploadError.transport(message)
        } catch {
            throw OneDriveUploadError.transport(String(describing: error))
        }
    }

    private struct DriveItem: Decodable {
        let name: String?
        let webUrl: String?
    }

    private func putToGraph(filename: String, body: Data, accessToken: String) async throws -> OneDriveUploadResult {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._ ")
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? filename
        guard let url = URL(string: "\(MicrosoftOAuthConfig.graphRootUploadBase)\(encodedName):/content") else {
            throw OneDriveUploadError.malformed("invalid upload URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do { (data, response) = try await urlSession.data(for: req) }
        catch { throw OneDriveUploadError.transport(String(describing: error)) }

        guard let http = response as? HTTPURLResponse else {
            throw OneDriveUploadError.graphStatus(code: 0, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OneDriveUploadError.graphStatus(
                code: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let item = try? JSONDecoder().decode(DriveItem.self, from: data)
        return OneDriveUploadResult(
            fileName: item?.name ?? filename,
            webURL: item?.webUrl.flatMap { URL(string: $0) },
            uploadedAt: Date()
        )
    }

    private static func filename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "VoxScribe Transcript \(formatter.string(from: date)).txt"
    }

    private static func renderFileBody(_ transcript: FinalizedTranscript) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var body = "VoxScribe Transcript\n"
        body += "Started: \(iso.string(from: transcript.startedAt))\n"
        body += "Ended: \(iso.string(from: transcript.endedAt))\n"
        body += "Mode: \(transcript.mode.rawValue)\n"
        body += "Transcriber: \(transcript.transcriber.rawValue)\n"
        body += "\n"
        body += transcript.renderedText
        if !body.hasSuffix("\n") { body += "\n" }
        return body
    }
}
