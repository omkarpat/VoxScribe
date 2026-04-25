import SwiftUI

struct TranscriptionView: View {
    @State private var preferences = SessionPreferences()
    @State private var oneDrive = OneDriveIntegration()
    @State private var session: TranscriptionSession?
    @State private var elapsed: TimeInterval = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptScroll
            errorBanner(displayedError ?? "")
                .opacity(displayedError == nil ? 0 : 1)
                .frame(height: displayedError == nil ? 0 : nil)
                .animation(.easeInOut(duration: 0.2), value: displayedError)
            controls
        }
        .task {
            await oneDrive.flushPendingUploads()
        }
        .onDisappear { timerTask?.cancel() }
        .onChange(of: sessionPhaseMarker) { _, _ in
            if case .failed = session?.phase {
                timerTask?.cancel()
                timerTask = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                preferences: preferences,
                oneDrive: oneDrive,
                isRecording: isRunning
            )
        }
    }

    private var displayedError: String? {
        if let errorMessage { return errorMessage }
        if case .failed(let err) = session?.phase { return err.userMessage }
        return nil
    }

    private var sessionPhaseMarker: Int {
        switch session?.phase {
        case .failed: return 3
        case .running: return 2
        case .starting, .stopping: return 1
        default: return 0
        }
    }

    // MARK: - subviews

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            Text(elapsedString)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()
            statusIndicator
        }
        .padding()
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptContent
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session?.segments.count ?? 0) { _, _ in
                withAnimation { proxy.scrollTo("partial-anchor", anchor: .bottom) }
            }
            .onChange(of: session?.partial ?? "") { _, _ in
                proxy.scrollTo("partial-anchor", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if let session {
                ForEach(session.segments) { segment in
                    segmentView(segment)
                }
                if !session.partial.isEmpty {
                    Text(session.partial)
                        .italic()
                        .foregroundStyle(.tertiary)
                }
                Color.clear.frame(height: 1).id("partial-anchor")
            } else {
                Text("Tap Record to start.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: TranscriptSegment) -> some View {
        let color: Color = (segment.state == .corrected) ? .primary : .secondary
        Text(segment.text)
            .foregroundStyle(color)
            .animation(.easeInOut(duration: 0.2), value: segment.text)
            .id(segment.id)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .padding(.horizontal, 16)
    }

    private var controls: some View {
        HStack {
            Spacer()
            recordButton
            Spacer()
        }
        .padding(.vertical, 20)
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .fill(isRunning ? Color.red : Color.accentColor)
                    .frame(width: 88, height: 88)
                Image(systemName: isRunning ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(phaseIsTransitioning)
    }

    private var statusIndicator: some View {
        Group {
            switch session?.phase ?? .idle {
            case .idle, .stopped:
                Text("Ready").font(.caption).foregroundStyle(.secondary)
            case .starting:
                HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Starting…").font(.caption) }
            case .running:
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Recording").font(.caption).foregroundStyle(.red)
                }
            case .stopping:
                HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Stopping…").font(.caption) }
            case .failed:
                Text("Error").font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - state helpers

    private var isRunning: Bool {
        if case .running = session?.phase { return true }
        return false
    }

    private var phaseIsTransitioning: Bool {
        switch session?.phase {
        case .starting, .stopping: return true
        default: return false
        }
    }

    private var elapsedString: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - actions

    private func toggleRecording() {
        if isRunning {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        errorMessage = nil
        let newSession = TranscriptionSession(
            vocabulary: { [preferences] in preferences.vocabulary },
            profile: { [preferences] in preferences.mode },
            localPartialsEnabled: { [preferences] in preferences.localPartialsEnabled }
        )
        session = newSession
        await newSession.start()
        if case .failed(let sessionError) = newSession.phase {
            errorMessage = sessionError.userMessage
            return
        }
        startTimer()
    }

    private func stopRecording() async {
        timerTask?.cancel()
        timerTask = nil
        guard let session else { return }
        await session.stop()
        let finalized = await session.finalizeForExport()
        await oneDrive.uploadFinalizedTranscript(finalized)
    }

    private func startTimer() {
        let started = Date()
        elapsed = 0
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                elapsed = Date().timeIntervalSince(started)
            }
        }
    }
}

#Preview {
    TranscriptionView()
}
