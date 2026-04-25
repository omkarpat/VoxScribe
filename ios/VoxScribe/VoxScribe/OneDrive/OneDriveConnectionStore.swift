import Foundation
import Observation

enum OneDriveStatus: String, Codable, Equatable, Sendable {
    case disconnected
    case connected
    case expired
}

enum UploadStatus: String, Codable, Equatable, Sendable {
    case inProgress
    case success
    case failed
}

struct OneDriveConnectionState: Codable, Equatable, Sendable {
    var status: OneDriveStatus
    var email: String?
    var displayName: String?
    var lastUploadAt: Date?
    var lastUploadStatus: UploadStatus?
    var lastUploadError: String?

    static let disconnected = OneDriveConnectionState(
        status: .disconnected,
        email: nil,
        displayName: nil,
        lastUploadAt: nil,
        lastUploadStatus: nil,
        lastUploadError: nil
    )
}

@Observable
final class OneDriveConnectionStore {
    private(set) var state: OneDriveConnectionState

    private let defaults: UserDefaults
    private static let key = "voxscribe.onedrive.state.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? Self.decoder.decode(OneDriveConnectionState.self, from: data) {
            self.state = decoded
        } else {
            self.state = .disconnected
        }
    }

    func markConnected(email: String?, displayName: String?) {
        state = OneDriveConnectionState(
            status: .connected,
            email: email,
            displayName: displayName,
            lastUploadAt: nil,
            lastUploadStatus: nil,
            lastUploadError: nil
        )
        persist()
    }

    func markDisconnected() {
        state = .disconnected
        persist()
    }

    func markExpired() {
        state.status = .expired
        state.lastUploadStatus = .failed
        persist()
    }

    func markUploadInProgress() {
        state.lastUploadStatus = .inProgress
        state.lastUploadError = nil
        persist()
    }

    func markUploadSuccess(at date: Date = Date()) {
        state.lastUploadAt = date
        state.lastUploadStatus = .success
        state.lastUploadError = nil
        persist()
    }

    func markUploadFailed(message: String?) {
        state.lastUploadStatus = .failed
        state.lastUploadError = message
        persist()
    }

    private func persist() {
        if let data = try? Self.encoder.encode(state) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
