import Foundation
import Observation

struct SessionVocabulary: Sendable, Equatable {
    let keytermsPrompt: [String]
    let protectedTerms: [String]
    let transcriber: Transcriber
    let revision: Int
}

enum Transcriber: String, CaseIterable, Codable, Sendable, Identifiable {
    case standard
    case multilingual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .multilingual: return "Multilingual"
        }
    }

    /// Matches `Transcriber` in `schemas.py`.
    var serverValue: String { rawValue }

    var supportsKeyterms: Bool { self == .standard }
}

enum CorrectionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case standard
    case dictation
    case code

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .dictation: return "Dictation"
        case .code: return "Code"
        }
    }

    /// Matches the server's `CorrectionProfile` values in `schemas.py`. Code
    /// mode uses the separate `/correct_code` endpoint and has no profile.
    var serverProfile: String? {
        switch self {
        case .standard: return "default"
        case .dictation: return "dictation"
        case .code: return nil
        }
    }

    var usesCodeEndpoint: Bool { self == .code }
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
    var transcriber: Transcriber {
        didSet {
            guard oldValue != transcriber else { return }
            defaults.set(transcriber.rawValue, forKey: Self.transcriberKey)
            revision += 1
            // Code mode is English Standard-only at launch. If the user picks
            // multilingual while Code is selected, revert to Standard rather
            // than leave an unsupported mode active.
            if transcriber == .multilingual && mode == .code {
                mode = .standard
            }
        }
    }
    var localPartialsEnabled: Bool {
        didSet {
            guard oldValue != localPartialsEnabled else { return }
            defaults.set(localPartialsEnabled, forKey: Self.localPartialsKey)
        }
    }

    private let defaults: UserDefaults
    private static let termsKey = "voxscribe.keyterms.v1"
    private static let modeKey = "voxscribe.correctionMode.v1"
    private static let transcriberKey = "voxscribe.transcriber.v1"
    private static let localPartialsKey = "voxscribe.localPartials.v1"

    static let defaultTerms: [String] = [
        "bhai",
        "theek hai",
        "chai",
        "haan",
        "na",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.termsKey),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            self.terms = stored
        } else {
            self.terms = Self.defaultTerms
        }
        if let raw = defaults.string(forKey: Self.modeKey) {
            if let stored = CorrectionMode(rawValue: raw) {
                self.mode = stored
            } else {
                // Migration: retired modes (e.g. "structured") fold into Standard.
                self.mode = .standard
                defaults.set(CorrectionMode.standard.rawValue, forKey: Self.modeKey)
            }
        } else {
            self.mode = .standard
        }
        if let raw = defaults.string(forKey: Self.transcriberKey),
           let stored = Transcriber(rawValue: raw) {
            self.transcriber = stored
        } else {
            self.transcriber = .standard
        }
        if defaults.object(forKey: Self.localPartialsKey) != nil {
            self.localPartialsEnabled = defaults.bool(forKey: Self.localPartialsKey)
        } else {
            self.localPartialsEnabled = true
        }
        self.revision = 1
    }

    var vocabulary: SessionVocabulary {
        let activeTerms = transcriber.supportsKeyterms ? terms : []
        return SessionVocabulary(
            keytermsPrompt: activeTerms,
            protectedTerms: activeTerms,
            transcriber: transcriber,
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
