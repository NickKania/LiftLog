import XCTest
@testable import LiftLogCore

final class WorkoutImportTests: XCTestCase {
    private let header = "Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,RPE\n"
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func preview(_ rows: String, catalog: [Exercise] = []) throws -> WorkoutImportPreview {
        try StrongWorkoutImporter.preview(csv: header + rows, unit: .lb, timeZone: utc, catalog: catalog)
    }

    func testStrongRowsGroupAndPreserveSetOrderWithoutInventingTargets() throws {
        let value = try preview("""
        2025-01-02 10:00:00,Upper,1h 5m,Bench,1,50,10.0,0,0,
        2025-01-02 10:00:00,Upper,1h 5m,Bench,Rest Timer,0,0,0,120,
        2025-01-02 10:00:00,Upper,1h 5m,Fly,1,20,8,0,0,
        2025-01-02 10:00:00,Upper,1h 5m,Bench,2,45,9,0,0,
        2025-01-01 10:00:00,Lower,30m,Squat,1,70,5,0,0,
        """)
        XCTAssertEqual(value.workouts.count, 2)
        let selected = value.sessions(selectedIDs: [value.workouts[1].id])
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected[0].name, "Lower")
        XCTAssertEqual(selected[0].exercises[0].exercise.name, "Squat")
        XCTAssertEqual(selected[0].exercises[0].sets[0].weight, 70)
        XCTAssertEqual(value.skippedRestRows, 1)
        XCTAssertTrue(value.warnings.isEmpty)
        let session = value.workouts[0].session
        XCTAssertEqual(session.exercises.map(\.exercise.name), ["Bench", "Fly"])
        XCTAssertEqual(session.exercises[0].sets.map(\.reps), [10, 9])
        XCTAssertEqual(session.finishedAt!.timeIntervalSince(session.startedAt), 3900)
        XCTAssertTrue(session.exercises.flatMap(\.sets).allSatisfy { $0.isCompleted && $0.targetReps == nil })
    }

    func testQuotedCommasEscapedQuotesNewlinesBOMCRLFAndReorderedHeaders() throws {
        let text = "\u{FEFF}Exercise Name,Date,Workout Name,Duration,Set Order,Weight,Reps,Distance,Seconds,RPE\r\n\"Press, \"\"incline\"\"\",2025-01-02 10:00:00,\"Upper\r\nbody\",55m,1,12.5,10.0,0,0,\r\n"
        let value = try StrongWorkoutImporter.preview(csv: text, unit: .kg, timeZone: utc, catalog: [])
        XCTAssertEqual(value.workouts[0].session.name, "Upper\nbody")
        XCTAssertEqual(value.exerciseMappings[0].sourceName, "Press, \"incline\"")
        XCTAssertEqual(value.workouts[0].session.unit, .kg)
    }

    func testInvalidCSVAndUnsupportedFormatsThrow() {
        for text in ["", "date,name\na,b", header + "\"unfinished", header + "a,\"b\"oops"] {
            XCTAssertThrowsError(try StrongWorkoutImporter.preview(csv: text, unit: .lb, timeZone: utc, catalog: []))
        }
    }

    func testSkippedRowsAreExplainedAndRPELossWarns() throws {
        let value = try preview("""
        2025-01-02 10:00:00,Upper,55m,Bench,1,50,10,0,0,8
        2025-01-02 10:00:00,Upper,55m,Run,1,0,0,1000,120,
        2025-01-02 10:00:00,Upper,55m,Bench,2,-1,8,0,0,
        2025-01-02 10:00:00,Upper,55m,Bench,3,nan,8,0,0,
        2025-01-02 10:00:00,Upper,55m,Bench,4,20,8.5,0,0,
        broken,row
        """)
        XCTAssertEqual(value.workouts.count, 1)
        XCTAssertEqual(value.workouts[0].session.exercises.flatMap(\.sets).count, 1)
        XCTAssertEqual(value.warnings.count, 6)
        XCTAssertEqual(value.warnings.map(\.row), [2, 3, 4, 5, 6, 7])
    }

    func testBadDatesDurationsAndConflictingDurationInvalidateWorkout() throws {
        for duration in ["", "0m", "55", "1m1m", "forever", "999999999999999999999h"] {
            XCTAssertTrue(try preview("2025-01-02 10:00:00,Upper,\(duration),Bench,1,10,8,0,0,").workouts.isEmpty)
        }
        XCTAssertTrue(try preview("2025-02-30 10:00:00,Upper,55m,Bench,1,10,8,0,0,").workouts.isEmpty)
        let conflicting = try preview("""
        2025-01-02 10:00:00,Upper,55m,Bench,1,10,8,0,0,
        2025-01-02 10:00:00,Upper,56m,Bench,2,10,8,0,0,
        """)
        XCTAssertTrue(conflicting.workouts.isEmpty)
        let unsupportedFirst = try preview("""
        2025-01-02 10:00:00,Upper,55m,Run,1,0,0,1000,120,
        2025-01-02 10:00:00,Upper,56m,Bench,1,10,8,0,0,
        """)
        XCTAssertTrue(unsupportedFirst.workouts.isEmpty)
    }

    func testOnlyExactNormalizedNamesMatchAndOverridesKeepSourceIdentity() throws {
        let bench = Exercise(name: "bench press", category: "Chest")
        let incline = Exercise(name: "Incline Press", category: "Chest")
        let value = try preview("""
        2025-01-02 10:00:00,Upper,55m,BENCH  PRESS,1,10,8,0,0,
        2025-01-02 10:00:00,Upper,55m,Press,1,10,8,0,0,
        """, catalog: [bench, incline])
        XCTAssertEqual(value.exerciseMappings[0].matchedExercise, bench)
        XCTAssertNil(value.exerciseMappings[1].matchedExercise)
        let selected = Set(value.workouts.map(\.id))
        let defaults = value.sessions(selectedIDs: selected)
        XCTAssertEqual(defaults[0].exercises[0].exercise, bench)
        XCTAssertEqual(defaults[0].exercises[1].exercise.name, "Press")
        XCTAssertEqual(defaults[0].exercises[1].exercise.category, "Custom")
        let overrides = value.sessions(selectedIDs: selected, exerciseOverrides: ["Press": incline])
        XCTAssertEqual(overrides[0].exercises[1].exercise, incline)
        XCTAssertEqual(overrides[0].importSourceKey, defaults[0].importSourceKey)
        XCTAssertTrue(value.sessions(selectedIDs: []).isEmpty)
    }

    func testSourceIdentityIndependentOfUnitsTimezoneAndMapping() throws {
        let csv = header + "2025-01-02 10:00:00,Upper,55m,Bench,1,10,8,0,0,"
        let first = try StrongWorkoutImporter.preview(csv: csv, unit: .lb, timeZone: utc, catalog: [])
        let second = try StrongWorkoutImporter.preview(csv: csv, unit: .kg, timeZone: TimeZone(secondsFromGMT: 3600)!, catalog: [Exercise(name: "Bench")])
        XCTAssertEqual(first.workouts[0].id, second.workouts[0].id)
        XCTAssertNotEqual(first.workouts[0].session.startedAt, second.workouts[0].session.startedAt)
    }

    @MainActor func testAtomicImportPersistsSkipsDuplicatesAndKeepsActiveWorkout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workouts.sqlite")
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.startWorkout())
        let active = store.activeWorkout
        let value = try preview("""
        2025-01-01 10:00:00,Older,55m,Bench,1,10,8,0,0,
        2025-01-02 10:00:00,Newer,55m,Bench,1,10,8,0,0,
        """)
        let sessions = value.sessions(selectedIDs: Set(value.workouts.map(\.id)))
        let result = store.importWorkouts(sessions + [sessions[0]])
        XCTAssertEqual(result?.importedCount, 2)
        XCTAssertEqual(result?.skippedDuplicateCount, 1)
        XCTAssertEqual(store.history.map(\.name), ["Newer", "Older"])
        XCTAssertEqual(store.activeWorkout, active)
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.importWorkouts(sessions)?.skippedDuplicateCount, 2)
        XCTAssertEqual(reloaded.history.count, 2)
        let before = try Data(contentsOf: url)
        var invalid = sessions[0]
        invalid.importSourceKey = "new-key"
        invalid.exercises[0].sets[0].reps = 0
        XCTAssertNil(reloaded.importWorkouts([invalid]))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(reloaded.history.count, 2)
        for dates in [(Date(timeIntervalSince1970: .infinity), Date()), (Date(), Date(timeIntervalSince1970: 0)), (Date(), Date().addingTimeInterval(8 * 24 * 3600))] {
            var malformed = sessions[0]
            malformed.importSourceKey = UUID().uuidString
            malformed.startedAt = dates.0
            malformed.finishedAt = dates.1
            XCTAssertNil(reloaded.importWorkouts([malformed]))
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }

    @MainActor func testFailedDiskWriteDoesNotPublishImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workouts.sqlite")
        let store = WorkoutStore(fileURL: url)
        let templates = store.templates
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let value = try preview("2025-01-02 10:00:00,Upper,55m,Bench,1,10,8,0,0,")
        XCTAssertNil(store.importWorkouts(value.sessions(selectedIDs: Set(value.workouts.map(\.id)))))
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.templates, templates)
        XCTAssertNotNil(store.errorMessage)
    }

    func testSessionWithoutProvenanceStillDecodes() throws {
        let session = WorkoutSession(name: "Legacy")
        let data = try JSONEncoder().encode(session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["importSourceKey"])
        XCTAssertNil(try JSONDecoder().decode(WorkoutSession.self, from: data).importSourceKey)
    }

    func testProvidedStrongExportFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "strong_workouts", withExtension: "csv", subdirectory: "Fixtures"))
        let csv = try String(contentsOf: url, encoding: .utf8)
        let value = try StrongWorkoutImporter.preview(csv: csv, unit: .lb, timeZone: utc, catalog: ExerciseCatalog.all)
        XCTAssertEqual(value.workouts.count, 1)
        let session = value.workouts[0].session
        XCTAssertEqual(session.name, "Morning Workout")
        let expectedStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-03T10:20:37Z"))
        XCTAssertEqual(session.startedAt, expectedStart)
        XCTAssertEqual(session.finishedAt, expectedStart.addingTimeInterval(55 * 60))
        XCTAssertEqual(session.exercises.map(\.exercise.name), [
            "Bench Press (Dumbbell)", "Incline Bench Press (Dumbbell)", "Chest Fly",
            "Triceps Pushdown (Cable - Straight Bar)", "Triceps Extension"
        ])
        let weights: [Double] = [50, 40, 27.5, 37.5, 37.5]
        let reps = [[10, 9, 7, 5], [10, 7, 6, 6], [10, 9, 8, 7], [10, 10, 10, 10], [10, 10, 9, 6]]
        for index in session.exercises.indices {
            XCTAssertEqual(session.exercises[index].sets.map(\.weight), Array(repeating: weights[index], count: 4))
            XCTAssertEqual(session.exercises[index].sets.map(\.reps), reps[index])
        }
        XCTAssertEqual(value.workouts[0].session.exercises.count, 5)
        XCTAssertEqual(value.workouts[0].session.exercises.flatMap(\.sets).count, 20)
        XCTAssertEqual(value.workouts[0].session.exercises.flatMap(\.sets).reduce(0) { $0 + $1.reps }, 169)
        XCTAssertEqual(value.workouts[0].session.finishedAt!.timeIntervalSince(value.workouts[0].session.startedAt), 55 * 60)
        XCTAssertEqual(value.skippedRestRows, 20)
        XCTAssertTrue(value.warnings.isEmpty)
    }
}
