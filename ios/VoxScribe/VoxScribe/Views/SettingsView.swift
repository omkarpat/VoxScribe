import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: SessionPreferences
    let isRecording: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var newTerm: String = ""
    @State private var editingIndex: Int?
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
                ForEach(CorrectionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Correction mode")
        } footer: {
            Text(modeFooter)
        }
    }

    private var modeFooter: String {
        switch preferences.mode {
        case .standard:
            return "Punctuation, casing, and light cleanup. Protects keyterms."
        case .dictation:
            return "Standard plus spoken punctuation and line/paragraph commands."
        case .structured:
            return "Standard plus normalization of emails, phone numbers, URLs, IDs, and versions."
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
            ForEach(preferences.terms.indices, id: \.self) { index in
                row(for: preferences.terms[index], at: index)
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
        if editingIndex == index {
            HStack {
                TextField("Term", text: $editingDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(at: index) }
                Button("Save") { commitRename(at: index) }
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
                    beginRename(at: index)
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
        if let editingIndex, !preferences.terms.indices.contains(editingIndex) {
            cancelRename()
        }
    }

    private func beginRename(at index: Int) {
        editingIndex = index
        editingDraft = preferences.terms[index]
        renameFieldFocused = true
    }

    private func commitRename(at index: Int) {
        _ = preferences.update(at: index, to: editingDraft)
        cancelRename()
    }

    private func cancelRename() {
        editingIndex = nil
        editingDraft = ""
    }
}

#Preview {
    SettingsView(preferences: SessionPreferences(), isRecording: false)
}
