import Foundation
import Observation

struct SessionVocabulary: Sendable, Equatable {
    let keytermsPrompt: [String]
    let protectedTerms: [String]
    let revision: Int
}

enum CorrectionMode: String, CaseIterable, Sendable, Identifiable {
    case standard
    case dictation
    case structured

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .dictation: return "Dictation"
        case .structured: return "Structured"
        }
    }

    /// Matches the server's `CorrectionProfile` values in `schemas.py`.
    var serverProfile: String {
        switch self {
        case .standard: return "default"
        case .dictation: return "dictation"
        case .structured: return "structured_entry"
        }
    }
}

@Observable
@MainActor
final class SessionPreferences {
    private(set) var terms: [String]
    private(set) var revision: Int
    var mode: CorrectionMode {
        didSet {
            guard oldValue != mode else { return }
            defaults.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    private let defaults: UserDefaults
    private static let termsKey = "voxscribe.keyterms.v1"
    private static let modeKey = "voxscribe.correctionMode.v1"

    static let defaultTerms: [String] = [
        "Anthropic",
        "Claude",
        "Haiku",
        "Sonnet",
        "Opus",
        "AssemblyAI",
        "WebSocket",
        "FastAPI",
        "uvicorn",
        "SwiftUI",
        "Xcode",
        "AVAudioEngine",
        "PCM",
        "ASR",
        "VAD",
        "LLM",
        "prompt caching",
        "VoxScribe",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.termsKey),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            self.terms = stored
        } else {
            self.terms = Self.defaultTerms
        }
        if let raw = defaults.string(forKey: Self.modeKey),
           let stored = CorrectionMode(rawValue: raw) {
            self.mode = stored
        } else {
            self.mode = .standard
        }
        self.revision = 1
    }

    var vocabulary: SessionVocabulary {
        SessionVocabulary(
            keytermsPrompt: terms,
            protectedTerms: terms,
            revision: revision
        )
    }

    // MARK: - Mutations

    /// Adds `term` to the end of the list. Returns true if the term was added,
    /// false if it was empty, whitespace-only, or a case-insensitive duplicate.
    @discardableResult
    func add(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        terms.append(trimmed)
        bump()
        return true
    }

    func remove(at index: Int) {
        guard terms.indices.contains(index) else { return }
        terms.remove(at: index)
        bump()
    }

    /// Updates the term at `index`. Returns true if changed.
    @discardableResult
    func update(at index: Int, to newValue: String) -> Bool {
        guard terms.indices.contains(index) else { return false }
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != terms[index] else { return false }
        let duplicate = terms.enumerated().contains { i, existing in
            i != index && existing.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !duplicate else { return false }
        terms[index] = trimmed
        bump()
        return true
    }

    func resetToDefaults() {
        terms = Self.defaultTerms
        bump()
    }

    private func bump() {
        revision += 1
        persistTerms()
    }

    private func persistTerms() {
        if let data = try? JSONEncoder().encode(terms) {
            defaults.set(data, forKey: Self.termsKey)
        }
    }
}
