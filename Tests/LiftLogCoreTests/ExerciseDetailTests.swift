import Foundation
import XCTest
@testable import LiftLogCore

final class ExerciseDetailTests: XCTestCase {
    private func detail(_ sourceID: String) throws -> ExerciseDetail {
        try XCTUnwrap(ExerciseCatalog.details.values.first { $0.source.sourceRecordID == sourceID })
    }

    func testDetailsCoverStableCatalogIdentitiesWithoutChangingSnapshots() throws {
        XCTAssertEqual(ExerciseCatalog.all.count, 876)
        XCTAssertEqual(Set(ExerciseCatalog.details.keys), Set(ExerciseCatalog.all.map(\.id)))
        XCTAssertEqual(ExerciseCatalog.all.prefix(10).map(\.name), [
            "Bench Press", "Squat", "Deadlift", "Overhead Press", "Barbell Row",
            "Pull Up", "Dumbbell Curl", "Triceps Pushdown", "Romanian Deadlift", "Leg Press"
        ])
        for (index, exercise) in ExerciseCatalog.all.prefix(10).enumerated() {
            XCTAssertEqual(exercise.id.uuidString.lowercased(), String(format: "00000000-0000-0000-0000-%012d", index + 1))
        }
        let snapshot = Exercise(id: UUID(), name: "Retired snapshot", category: "Recorded category")
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "name", "category"])
        XCTAssertEqual(try JSONDecoder().decode(Exercise.self, from: encoded), snapshot)
        XCTAssertNil(ExerciseCatalog.detail(for: snapshot.id))
    }

    func testUnknownEquipmentAndOptionalMetadataRemainDistinctFromBodyweight() throws {
        XCTAssertNil(try detail("Adductor_Groin").equipment)
        XCTAssertEqual(try detail("3_4_Sit-Up").equipment, "Bodyweight")
        XCTAssertNil(try detail("Balance_Board").force)
        XCTAssertNil(try detail("90_90_Hamstring").mechanic)
        XCTAssertEqual(ExerciseCatalog.details.values.filter { $0.equipment == nil }.count, 77)
        XCTAssertEqual(ExerciseCatalog.details.values.filter { $0.instructions.isEmpty }.count, 5)
        XCTAssertEqual(try detail("Iron_Cross").instructions, [])
        XCTAssertEqual(try detail("3_4_Sit-Up").secondaryMuscles, [])
    }

    func testFullMuscleListsAndSourceInstructionOrderLoadOffline() throws {
        let bench = try detail("Barbell_Bench_Press_-_Medium_Grip")
        XCTAssertEqual(bench.equipment, "Barbell")
        XCTAssertEqual(bench.primaryMuscles, ["Chest"])
        XCTAssertEqual(bench.secondaryMuscles, ["Shoulders", "Triceps"])
        XCTAssertEqual(bench.type, "Strength")
        XCTAssertEqual(bench.level, "Beginner")
        XCTAssertEqual(bench.force, "Push")
        XCTAssertEqual(bench.mechanic, "Compound")
        let sitUp = try detail("3_4_Sit-Up")
        XCTAssertEqual(sitUp.instructions.count, 5)
        XCTAssertEqual(sitUp.instructions.first, "Lie down on the floor and secure your feet. Your legs should be bent at the knees.")
        XCTAssertEqual(sitUp.instructions.last, "Repeat for the recommended amount of repetitions.")
    }

    func testEveryFieldResolvesToPinnedSourceLicenseAndPendingReview() throws {
        let manifest = ExerciseCatalog.attribution
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.sources.count, 1)
        let source = try XCTUnwrap(manifest.sources.first)
        XCTAssertEqual(source.id, "free-exercise-db")
        XCTAssertEqual(source.revision, "f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5")
        XCTAssertEqual(source.sourceSHA256, "5bb747e3fc658f095a60dcbf6d53c96627acdcc6ffb6fffde86f7e26995d40bf")
        XCTAssertEqual(source.licenseID, "Unlicense")
        XCTAssertTrue(source.licenseText.contains("Anyone is free to copy, modify, publish, use, compile, sell, or"))
        XCTAssertTrue(source.licenseScope.contains("photographs are excluded"))
        XCTAssertEqual(source.reviewStatus, "pendingReview")
        XCTAssertFalse(source.credit.isEmpty)
        XCTAssertFalse(source.author.isEmpty)
        XCTAssertFalse(source.excludedContent.isEmpty)
        let fields: Set<String> = ["equipment", "primaryMuscles", "secondaryMuscles", "instructions", "type", "level", "force", "mechanic"]
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for detail in ExerciseCatalog.details.values {
            XCTAssertEqual(detail.source.sourceID, source.id)
            XCTAssertTrue(detail.source.sourceURL.absoluteString.contains(source.revision))
            XCTAssertEqual(detail.source.sourceRecordSHA256.count, 64)
            XCTAssertEqual(Set(detail.provenance.keys), fields)
            for provenance in detail.provenance.values {
                XCTAssertEqual(provenance.reviewStatus, "pendingReview")
                XCTAssertEqual(provenance.contentSHA256.count, 64)
                XCTAssertTrue(provenance.contentSHA256.unicodeScalars.allSatisfy(hex.contains))
            }
        }
    }
}
