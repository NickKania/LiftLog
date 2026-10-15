import Foundation

/// Replaceable bundled content, separate from the exercise snapshots saved in workouts.
struct ExerciseDetail: Codable, Equatable {
    var equipment: String?
    var primaryMuscles: [String]
    var secondaryMuscles: [String]
    /// Source wording awaiting individual correctness review; not professionally validated.
    var instructions: [String]
    var type: String?
    var level: String?
    var force: String?
    var mechanic: String?
    var source: ExerciseRecordProvenance
    var provenance: [String: ExerciseFieldProvenance]
}

/// Each field inherits this record and the license, author, revision, and credit of
/// the matching `ExerciseContentSource` in the generated attribution manifest.
struct ExerciseRecordProvenance: Codable, Equatable {
    var sourceID: String
    var sourceRecordID: String
    var sourceURL: URL
    var sourceRecordSHA256: String
}

struct ExerciseFieldProvenance: Codable, Equatable {
    var sourceField: String
    /// Hash of the original source field before normalization. See the generator
    /// for canonical JSON encoding; null and empty lists have distinct hashes.
    var contentSHA256: String
    var modifications: [String]
    var reviewStatus: String
}

struct ExerciseAttributionManifest: Codable, Equatable {
    var schemaVersion: Int
    var sources: [ExerciseContentSource]
}

struct ExerciseContentSource: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var repositoryURL: URL
    var revision: String
    var sourceURL: URL
    var sourceSHA256: String
    var author: String
    var licenseID: String
    var licenseURL: URL
    var licenseText: String
    var licenseSHA256: String
    var licenseScope: String
    var credit: String
    var modifications: [String]
    var reviewStatus: String
    var reviewNote: String
    var excludedContent: [String]
    var compatibilityMappingsSHA256: String
    var normalizationSHA256: String
}
