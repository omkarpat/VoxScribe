import Foundation

nonisolated struct PendingTranscriptUpload: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let transcript: FinalizedTranscript
    var attempts: Int
    var lastError: String?
}

nonisolated enum TranscriptUploadStoreError: Error {
    case directoryUnavailable(String)
    case encoding(String)
    case decoding(String)
    case io(String)
}

nonisolated struct TranscriptUploadStore: Sendable {
    private let directory: URL

    init() throws {
        let fm = FileManager.default
        do {
            let support = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directory = support.appendingPathComponent(
                "OneDrivePendingUploads",
                isDirectory: true
            )
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw TranscriptUploadStoreError.directoryUnavailable(String(describing: error))
        }
    }

    func save(_ upload: PendingTranscriptUpload) throws {
        let data: Data
        do { data = try Self.encoder.encode(upload) }
        catch { throw TranscriptUploadStoreError.encoding(String(describing: error)) }
        let url = fileURL(for: upload.id)
        do { try data.write(to: url, options: .atomic) }
        catch { throw TranscriptUploadStoreError.io(String(describing: error)) }
    }

    func delete(id: String) {
        let url = fileURL(for: id)
        try? FileManager.default.removeItem(at: url)
    }

    func loadAll() throws -> [PendingTranscriptUpload] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw TranscriptUploadStoreError.io(String(describing: error))
        }
        let jsons = contents.filter { $0.pathExtension == "json" }
        let decoded: [PendingTranscriptUpload] = jsons.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(PendingTranscriptUpload.self, from: data)
        }
        return decoded.sorted { $0.createdAt < $1.createdAt }
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
