import Foundation

/// Bundled public-domain catalog generated from free-exercise-db.
/// Source revision, license, and compatibility policy: docs/EXERCISE_CATALOG.md.
enum ExerciseCatalog {
    static let all: [Exercise] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "exercise-catalog", withExtension: "json") else {
            preconditionFailure("The bundled exercise catalog is missing.")
        }
        do {
            return try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("The bundled exercise catalog is invalid: \(error)")
        }
    }()
}
