import Foundation
import Observation

struct SessionVocabulary: Sendable, Equatable {
    let scenarioId: String
    let scenarioName: String
    let keytermsPrompt: [String]
    let protectedTerms: [String]
    let revision: Int
}

struct KeytermsScenario: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let terms: [String]
}

struct KeytermsCatalog: Decodable, Sendable {
    let defaultScenarioId: String
    let scenarios: [KeytermsScenario]

    static func loadBundled(resource: String = "demo-keyterms") -> KeytermsCatalog {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            fatalError("\(resource).json missing from app bundle — confirm Resources folder is inside the target.")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(KeytermsCatalog.self, from: data)
        } catch {
            fatalError("Failed to decode \(resource).json: \(error)")
        }
    }
}

@Observable
@MainActor
final class VocabularyResolver {
    let catalog: KeytermsCatalog
    private(set) var currentScenarioId: String
    private(set) var revision: Int = 1

    init(catalog: KeytermsCatalog) {
        precondition(!catalog.scenarios.isEmpty, "KeytermsCatalog must contain at least one scenario")
        self.catalog = catalog
        let defaultExists = catalog.scenarios.contains { $0.id == catalog.defaultScenarioId }
        self.currentScenarioId = defaultExists ? catalog.defaultScenarioId : catalog.scenarios[0].id
    }

    func setScenario(_ id: String) {
        guard id != currentScenarioId else { return }
        guard catalog.scenarios.contains(where: { $0.id == id }) else { return }
        currentScenarioId = id
        revision += 1
    }

    var current: SessionVocabulary {
        let scenario = catalog.scenarios.first { $0.id == currentScenarioId } ?? catalog.scenarios[0]
        return SessionVocabulary(
            scenarioId: scenario.id,
            scenarioName: scenario.name,
            keytermsPrompt: scenario.terms,
            protectedTerms: scenario.terms,
            revision: revision
        )
    }
}
