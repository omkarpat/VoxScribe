import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: SessionPreferences
    let oneDrive: OneDriveIntegration
    let isRecording: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var newTerm: String = ""
    @State private var editingTerm: String?
    @State private var editingDraft: String = ""
    @State private var errorMessage: String?
    @FocusState private var addFieldFocused: Bool
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                transcriberSection
                modeSection
                livePartialsSection
                if preferences.transcriber.supportsKeyterms {
                    keytermsSection
                }
                oneDriveSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            preferences.resetToDefaults()
                        } label: {
                            Label("Reset keyterms to defaults", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(isRecording)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Transcriber section

    private var transcriberSection: some View {
        Section {
            Picker("Transcriber", selection: $preferences.transcriber) {
                ForEach(Transcriber.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isRecording)
        } header: {
            Text("Transcriber")
        } footer: {
            Text(transcriberFooter)
        }
    }

    private var transcriberFooter: String {
        switch preferences.transcriber {
        case .standard:
            return "English only. Supports a custom keyterms dictionary."
        case .multilingual:
            return "Whisper-RT across 99 languages with auto language detection. Keyterms aren't supported in this mode."
        }
    }

    // MARK: - Mode section

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $preferences.mode) {
                ForEach(availableModes) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            if preferences.mode == .code {
                LabeledContent("Language", value: "Python")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Correction mode")
        } footer: {
            Text(modeFooter)
        }
    }

    /// Code mode is English Standard-only at launch, so it only appears in
    /// the picker when the Standard transcriber is selected.
    private var availableModes: [CorrectionMode] {
        switch preferences.transcriber {
        case .standard: return CorrectionMode.allCases
        case .multilingual: return CorrectionMode.allCases.filter { $0 != .code }
        }
    }

    private var modeFooter: String {
        switch preferences.mode {
        case .standard:
            return "Punctuation, casing, light cleanup, and normalization of complete emails, phone numbers, URLs, IDs, and versions. Protects keyterms."
        case .dictation:
            return "Standard plus spoken punctuation and line/paragraph commands."
        case .code:
            return "Optimized for editor use. Applies Python naming and symbol conventions to code-like utterances while keeping prose comments and docstrings readable. Python is the only supported code language right now."
        }
    }

    // MARK: - Live partials section

    private var livePartialsSection: some View {
        Section {
            Toggle("On-device partials", isOn: $preferences.localPartialsEnabled)
                .disabled(isRecording)
        } header: {
            Text("Live transcription")
        } footer: {
            Text("Uses Apple's on-device speech recognizer for snappier partials as you speak. Finals still come from the server. Changes apply on the next session.")
        }
    }

    // MARK: - OneDrive section

    private var oneDriveSection: some View {
        Section {
            oneDriveRows
        } header: {
            Text("OneDrive")
        } footer: {
            Text(oneDriveFooter)
        }
    }

    @ViewBuilder
    private var oneDriveRows: some View {
        let state = oneDrive.connectionStore.state
        switch state.status {
        case .disconnected:
            connectRow(title: "Connect Microsoft")
        case .connected:
            connectedRows(state: state)
        case .expired:
            expiredRows(state: state)
        }
        if let error = oneDrive.lastConnectError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func connectRow(title: String) -> some View {
        Button {
            Task { await oneDrive.connect() }
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(canConnect ? Color.accentColor : .secondary)
                Spacer()
                if oneDrive.connectInFlight {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(!canConnect)
    }

    @ViewBuilder
    private func connectedRows(state: OneDriveConnectionState) -> some View {
        LabeledContent("Connected") {
            if let email = state.email {
                Text(email).foregroundStyle(.secondary)
            }
        }
        if let secondary = uploadSecondaryText(for: state) {
            Text(secondary)
                .font(.footnote)
                .foregroundStyle(state.lastUploadStatus == .failed ? .red : .secondary)
        }
        Button(role: .destructive) {
            Task { await oneDrive.disconnect() }
        } label: {
            Text("Disconnect")
        }
        .disabled(isRecording)
    }

    @ViewBuilder
    private func expiredRows(state: OneDriveConnectionState) -> some View {
        LabeledContent("Microsoft connection expired") {
            if let email = state.email {
                Text(email).foregroundStyle(.secondary)
            }
        }
        connectRow(title: "Reconnect Microsoft")
    }

    private func uploadSecondaryText(for state: OneDriveConnectionState) -> String? {
        switch state.lastUploadStatus {
        case .inProgress: return "Last upload in progress…"
        case .failed: return "Last upload failed"
        case .success, .none: return nil
        }
    }

    private var canConnect: Bool {
        !isRecording && !oneDrive.connectInFlight
    }

    private var oneDriveFooter: String {
        let state = oneDrive.connectionStore.state
        switch state.status {
        case .disconnected:
            return "Completed sessions can upload automatically to your OneDrive."
        case .connected:
            if state.lastUploadStatus == .failed {
                return "We'll retry on your next completed session or when you reopen the app."
            }
            return "Completed sessions upload automatically to your OneDrive root folder."
        case .expired:
            return "Tap Reconnect Microsoft to reauthorize."
        }
    }

    // MARK: - Keyterms section

    private var keytermsSection: some View {
        Section {
            addRow
            termsRows
        } header: {
            Text("Keyterms (\(preferences.terms.count))")
        } footer: {
            Text("Keyterms bias the transcriber and are preserved in corrections. Changes apply on the next session.")
        }
    }

    @ViewBuilder
    private var addRow: some View {
        if isRecording {
            Text("Stop recording to edit keyterms.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                TextField("Add a term", text: $newTerm)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($addFieldFocused)
                    .onSubmit(commitNewTerm)
                Button(action: commitNewTerm) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(canAdd ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .accessibilityLabel("Add term")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var termsRows: some View {
        if preferences.terms.isEmpty {
            Text("No terms yet.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(preferences.terms.enumerated()), id: \.element) { index, term in
                row(for: term, at: index)
            }
            .onDelete { offsets in
                guard !isRecording else { return }
                delete(at: offsets)
            }
            .deleteDisabled(isRecording)
        }
    }

    @ViewBuilder
    private func row(for term: String, at index: Int) -> some View {
        if editingTerm == term {
            HStack {
                TextField("Term", text: $editingDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                Button("Save") { commitRename() }
                    .buttonStyle(.borderless)
                Button("Cancel") { cancelRename() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(term)
                .foregroundStyle(isRecording ? .secondary : .primary)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isRecording else { return }
                    beginRename(term)
                }
        }
    }

    private var canAdd: Bool {
        !newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commitNewTerm() {
        let candidate = newTerm
        if preferences.add(candidate) {
            newTerm = ""
            errorMessage = nil
            addFieldFocused = true
        } else if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = nil
        } else {
            errorMessage = "\"\(candidate.trimmingCharacters(in: .whitespacesAndNewlines))\" is already in the list."
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            preferences.remove(at: index)
        }
        if let editingTerm, !preferences.terms.contains(editingTerm) {
            cancelRename()
        }
    }

    private func beginRename(_ term: String) {
        editingTerm = term
        editingDraft = term
        renameFieldFocused = true
    }

    private func commitRename() {
        guard let editingTerm, let index = preferences.terms.firstIndex(of: editingTerm) else {
            cancelRename()
            return
        }
        _ = preferences.update(at: index, to: editingDraft)
        cancelRename()
    }

    private func cancelRename() {
        editingTerm = nil
        editingDraft = ""
    }
}

#Preview {
    SettingsView(
        preferences: SessionPreferences(),
        oneDrive: OneDriveIntegration(),
        isRecording: false
    )
}
