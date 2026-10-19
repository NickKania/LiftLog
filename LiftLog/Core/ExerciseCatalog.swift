import Foundation

/// Offline catalog generated from the pinned free-exercise-db snapshot.
/// Source license declaration and compatibility policy: docs/EXERCISE_CATALOG.md.
enum ExerciseCatalog {
    static let all: [Exercise] = load("exercise-catalog")

    /// Details are keyed by stable catalog identities and never added to saved snapshots.
    static let details: [UUID: ExerciseDetail] = {
        // JSON UUID object keys need explicit conversion; decoding a UUID-keyed
        // dictionary directly expects an alternating key/value array in Codable.
        let records: [String: ExerciseDetail] = load("exercise-details")
        var result: [UUID: ExerciseDetail] = [:]
        for (key, detail) in records {
            guard let id = UUID(uuidString: key), result[id] == nil else {
                preconditionFailure("The bundled exercise details contain an invalid or duplicate UUID.")
            }
            result[id] = detail
        }
        precondition(Set(result.keys) == Set(all.map(\.id)), "Exercise detail identities differ from the catalog.")
        let sourceIDs = Set(attribution.sources.map(\.id))
        precondition(result.values.allSatisfy { sourceIDs.contains($0.source.sourceID) }, "Exercise detail provenance is missing a source.")
        return result
    }()

    static let attribution: ExerciseAttributionManifest = load("exercise-attribution")

    /// Personal or retired exercise snapshots have no fabricated bundled content.
    static func detail(for exerciseID: UUID) -> ExerciseDetail? {
        details[exerciseID]
    }

    private static func load<T: Decodable>(_ resource: String) -> T {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            preconditionFailure("The bundled \(resource) resource is missing.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("The bundled \(resource) resource is invalid: \(error)")
        }
    }
}
