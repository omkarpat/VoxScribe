import Foundation
import Observation

@Observable
final class OneDriveIntegration {
    let connectionStore: OneDriveConnectionStore
    let authCoordinator: MicrosoftAuthCoordinator
    let tokenRefresher: MicrosoftTokenRefresher
    private let tokenStore: MicrosoftTokenStore
    private let uploadStore: TranscriptUploadStore?
    private let uploader: OneDriveUploader

    private(set) var connectInFlight: Bool = false
    private(set) var lastConnectError: String?

    init(
        connectionStore: OneDriveConnectionStore = OneDriveConnectionStore(),
        tokenStore: MicrosoftTokenStore = MicrosoftTokenStore(),
        authCoordinator: MicrosoftAuthCoordinator? = nil,
        tokenRefresher: MicrosoftTokenRefresher? = nil,
        uploadStore: TranscriptUploadStore? = nil
    ) {
        self.connectionStore = connectionStore
        self.tokenStore = tokenStore
        let refresher = tokenRefresher ?? MicrosoftTokenRefresher(tokenStore: tokenStore)
        self.authCoordinator = authCoordinator ?? MicrosoftAuthCoordinator(tokenStore: tokenStore)
        self.tokenRefresher = refresher
        self.uploadStore = uploadStore ?? (try? TranscriptUploadStore())
        self.uploader = OneDriveUploader(tokenRefresher: refresher)
        reconcileWithKeychain()
    }

    // MARK: - Connect / Disconnect

    func connect() async {
        connectInFlight = true
        lastConnectError = nil
        defer { connectInFlight = false }
        do {
            let tokens = try await authCoordinator.connect()
            connectionStore.markConnected(email: tokens.email, displayName: tokens.displayName)
            await flushPendingUploads()
        } catch MicrosoftAuthError.userCancelled {
            return
        } catch {
            lastConnectError = String(describing: error)
        }
    }

    func disconnect() async {
        do { try await tokenRefresher.disconnect() }
        catch { }
        connectionStore.markDisconnected()
    }

    // MARK: - Upload

    /// Persists a new transcript record and then flushes all pending uploads
    /// (including older stragglers) in creation order.
    func uploadFinalizedTranscript(_ transcript: FinalizedTranscript) async {
        guard connectionStore.state.status == .connected else { return }
        let pending = PendingTranscriptUpload(
            id: UUID().uuidString,
            createdAt: Date(),
            transcript: transcript,
            attempts: 0,
            lastError: nil
        )
        try? uploadStore?.save(pending)
        await flushPendingUploads()
    }

    func flushPendingUploads() async {
        guard let store = uploadStore else { return }
        guard connectionStore.state.status == .connected else { return }
        let records = (try? store.loadAll()) ?? []
        for record in records {
            await performUpload(record)
            if connectionStore.state.status == .expired { return }
        }
    }

    private func performUpload(_ record: PendingTranscriptUpload) async {
        var working = record
        working.attempts += 1
        try? uploadStore?.save(working)
        connectionStore.markUploadInProgress()

        do {
            let result = try await uploader.upload(record.transcript)
            uploadStore?.delete(id: record.id)
            connectionStore.markUploadSuccess(at: result.uploadedAt)
            print("[OneDrive] uploaded \(result.fileName) \(result.webURL?.absoluteString ?? "")")
        } catch OneDriveUploadError.connectionExpired {
            connectionStore.markExpired()
        } catch OneDriveUploadError.notConnected {
            uploadStore?.delete(id: record.id)
            connectionStore.markUploadFailed(message: "Not connected")
        } catch {
            working.lastError = String(describing: error)
            try? uploadStore?.save(working)
            connectionStore.markUploadFailed(message: String(describing: error))
        }
    }

    // MARK: - Startup reconciliation

    private func reconcileWithKeychain() {
        let keychainHasTokens: Bool = {
            do { return try tokenStore.load() != nil }
            catch { return false }
        }()
        if !keychainHasTokens && connectionStore.state.status != .disconnected {
            connectionStore.markDisconnected()
        }
    }
}
