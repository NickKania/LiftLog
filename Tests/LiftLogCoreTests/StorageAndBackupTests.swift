import Foundation
import XCTest
@testable import LiftLogCore

final class StorageAndBackupTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StorageTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func preferences() throws -> UserDefaults {
        let suite = "BackupTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func snapshot() -> WorkoutSnapshot {
        let exercise = Exercise(name: "Farmer’s Carry 'Heavy'", category: "Custom")
        let template = WorkoutTemplate(name: "Strength", exercises: [TemplateExercise(exercise: exercise, sets: [TemplateSet(weight: 20.5, targetReps: 7)])])
        let completed = WorkoutSession(templateID: template.id, name: "Imported", startedAt: Date(timeIntervalSinceReferenceDate: 100),
            finishedAt: Date(timeIntervalSinceReferenceDate: 200), unit: .lb, importSourceKey: "strong:fixture",
            exercises: [WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 45.25, reps: 6, targetReps: nil, isCompleted: true)])])
        let active = WorkoutSession(templateID: template.id, name: "In progress", startedAt: Date(timeIntervalSinceReferenceDate: 300), unit: .kg,
            exercises: [WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 20.5, reps: 5, targetReps: 7, isCompleted: true), WorkoutSet(reps: 7)])])
        return WorkoutSnapshot(templates: [template], history: [completed], activeWorkout: active, unit: .kg, personalExercises: [exercise])
    }

    private func assertEqual(_ actual: WorkoutSnapshot, _ expected: WorkoutSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.templates, expected.templates, file: file, line: line)
        XCTAssertEqual(actual.history, expected.history, file: file, line: line)
        XCTAssertEqual(actual.activeWorkout, expected.activeWorkout, file: file, line: line)
        XCTAssertEqual(actual.unit, expected.unit, file: file, line: line)
        XCTAssertEqual(actual.personalExercises, expected.personalExercises, file: file, line: line)
    }

    @MainActor
    func testJSONMigrationPreservesEveryFieldAndOriginalThenUsesSQLiteOnRelaunch() async throws {
        let folder = try directory()
        let legacy = folder.appendingPathComponent("workouts.json")
        let database = folder.appendingPathComponent("workouts.sqlite")
        let saved = snapshot()
        let original = try JSONEncoder().encode(saved)
        try original.write(to: legacy)
        let store = WorkoutStore(fileURL: database)
        XCTAssertNil(store.errorMessage)
        assertEqual(try WorkoutDatabase(url: database).load(), saved)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertEqual(String(decoding: try Data(contentsOf: database).prefix(15), as: UTF8.self), "SQLite format 3")
        XCTAssertTrue(store.setUnit(.lb))
        // The preserved legacy file must never override newer database contents.
        let reloaded = WorkoutStore(fileURL: database)
        XCTAssertEqual(reloaded.unit, .lb)
        XCTAssertEqual(reloaded.history, saved.history)
        XCTAssertEqual(reloaded.activeWorkout, saved.activeWorkout)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
    }

    #if os(macOS)
    @MainActor
    func testLaunchRecoversAnInterruptedSQLiteTransaction() async throws {
        let url = try directory().appendingPathComponent("workouts.sqlite")
        let saved = snapshot()
        try WorkoutDatabase(url: url).save(saved)
        // A separate process exits without closing SQLite, leaving an actual hot journal.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
            import os, sqlite3, sys
            connection = sqlite3.connect(sys.argv[1])
            connection.execute('PRAGMA cache_size = 1')
            connection.execute('BEGIN IMMEDIATE')
            connection.execute("UPDATE settings SET unit = 'lb'")
            connection.execute('UPDATE records SET name = ?', ('interrupted' * 10000,))
            os._exit(0)
            """, url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-journal"))
        let store = WorkoutStore(fileURL: url)
        XCTAssertNil(store.errorMessage)
        assertEqual(try WorkoutDatabase(url: url).load(), saved)
        XCTAssertTrue(store.setUnit(.lb))
    }
    #endif

    func testConstraintFailureRollsBackEveryTable() throws {
        let url = try directory().appendingPathComponent("workouts.sqlite")
        let database = WorkoutDatabase(url: url)
        let saved = snapshot()
        try database.save(saved)
        var invalid = saved
        invalid.templates[0].name = "Must roll back"
        invalid.templates[0].exercises[0].sets[0].weight = -1
        XCTAssertThrowsError(try database.save(invalid))
        assertEqual(try database.load(), saved)
    }

    @MainActor
    func testUnsupportedDatabaseVersionIsPreservedAndCannotBeSavedOver() async throws {
        let url = try directory().appendingPathComponent("workouts.sqlite")
        try WorkoutDatabase(url: url).save(snapshot())
        do { try SQLiteConnection(url: url).execute("PRAGMA user_version = 999") }
        let original = try Data(contentsOf: url)
        let store = WorkoutStore(fileURL: url)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.setUnit(.lb))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSnapshotContainsCommittedWALPagesAndIsStandalone() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("workouts.sqlite")
        let backup = folder.appendingPathComponent("backup.sqlite")
        let database = WorkoutDatabase(url: url)
        var saved = snapshot()
        try database.save(saved)
        let writer = try SQLiteConnection(url: url)
        _ = try writer.rows("PRAGMA journal_mode = WAL")
        try writer.execute("UPDATE settings SET unit = 'lb' WHERE id = 1")
        saved.unit = .lb
        try database.backup(to: backup)
        assertEqual(try WorkoutDatabase(url: backup).load(), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-wal"))
        XCTAssertThrowsError(try database.backup(to: backup))
    }

    @MainActor
    func testBackupRestorePreservesCurrentDataAndRestoresAllFields() async throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("workouts.sqlite")
        let cloud = folder.appendingPathComponent("Cloud", isDirectory: true)
        let saved = snapshot()
        try WorkoutDatabase(url: url).save(saved)
        let repository = CloudBackupRepository(directoryProvider: { cloud })
        let manager = CloudBackupManager(databaseURL: url, repository: repository, preferences: try preferences())
        let store = WorkoutStore(fileURL: url, cloudBackup: manager)
        await manager.backUpNow()
        XCTAssertNil(manager.errorMessage)
        let backup = try XCTUnwrap(manager.backups.first)
        XCTAssertTrue(store.setUnit(.lb))
        XCTAssertTrue(store.discardWorkout())
        let beforeRestore = try WorkoutDatabase(url: url).load()
        await manager.restore(backup, into: store)
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(store.isRestoring)
        assertEqual(try WorkoutDatabase(url: url).load(), saved)
        XCTAssertEqual(store.activeWorkout, saved.activeWorkout)
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("before-restore-") })
        assertEqual(try WorkoutDatabase(url: recovery).load(), beforeRestore)
        XCTAssertEqual(try WorkoutDatabase(url: backup.url).load().unit, .kg)
    }

    @MainActor
    func testCorruptBackupCannotReplaceLocalData() async throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("workouts.sqlite")
        let cloud = folder.appendingPathComponent("Cloud", isDirectory: true)
        let repository = CloudBackupRepository(directoryProvider: { cloud })
        let manager = CloudBackupManager(databaseURL: url, repository: repository, preferences: try preferences())
        let store = WorkoutStore(fileURL: url, cloudBackup: manager)
        await manager.backUpNow()
        let backup = try XCTUnwrap(manager.backups.first)
        try Data("broken backup".utf8).write(to: backup.url)
        let original = try Data(contentsOf: url)
        let templates = store.templates
        await manager.restore(backup, into: store)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(store.isRestoring)
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testValidBackupCanRecoverDamagedLocalDatabase() async throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("workouts.sqlite")
        let cloud = folder.appendingPathComponent("Cloud", isDirectory: true)
        let saved = snapshot()
        try WorkoutDatabase(url: url).save(saved)
        let repository = CloudBackupRepository(directoryProvider: { cloud })
        let backup = try await repository.createBackup(databaseURL: url, deviceID: UUID().uuidString)
        let corrupt = Data("damaged local database".utf8)
        try corrupt.write(to: url)
        let manager = CloudBackupManager(databaseURL: url, repository: repository, preferences: try preferences())
        let store = WorkoutStore(fileURL: url, cloudBackup: manager)
        XCTAssertNotNil(store.errorMessage)
        await manager.restore(backup, into: store)
        XCTAssertNil(manager.errorMessage)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.setUnit(.lb))
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("before-restore-") })
        XCTAssertEqual(try Data(contentsOf: recovery), corrupt)
    }

    @MainActor
    func testUnavailableCloudDoesNotBlockLocalSavesAndSettingPersists() async throws {
        let url = try directory().appendingPathComponent("workouts.sqlite")
        let defaults = try preferences()
        let repository = CloudBackupRepository(directoryProvider: { throw DatabaseError(message: "iCloud unavailable") })
        let manager = CloudBackupManager(databaseURL: url, repository: repository, preferences: defaults)
        let store = WorkoutStore(fileURL: url, cloudBackup: manager)
        manager.setAutomaticBackups(true)
        await manager.backUpNow()
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertEqual(WorkoutStore(fileURL: url).unit, .kg)
        let reloaded = CloudBackupManager(databaseURL: url, repository: repository, preferences: defaults)
        XCTAssertTrue(reloaded.automaticBackupsEnabled)
        manager.setAutomaticBackups(false)
        XCTAssertFalse(defaults.bool(forKey: "automaticCloudBackups"))
    }

    @MainActor
    func testEditsAreBlockedDuringRestore() async throws {
        let url = try directory().appendingPathComponent("workouts.sqlite")
        let store = WorkoutStore(fileURL: url)
        let before = try Data(contentsOf: url)
        store.beginRestore()
        XCTAssertFalse(store.setUnit(.kg))
        XCTAssertFalse(store.startWorkout())
        XCTAssertEqual(try Data(contentsOf: url), before)
        store.endRestore()
        XCTAssertTrue(store.setUnit(.kg))
    }

    func testRemoteMetadataListsBackupsWithoutDownloadedFiles() async throws {
        let folder = try directory().appendingPathComponent("Cloud", isDirectory: true)
        let repository = CloudBackupRepository(directoryProvider: { folder })
        let cloudFolder = try await repository.directory()
        let remote = CloudBackup(url: cloudFolder.appendingPathComponent("LiftLog-1000-remote.sqlite"),
            date: Date(timeIntervalSince1970: 1), byteCount: 1024, uploadStatus: "Uploaded to iCloud")
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.url.path))
        let listed = try await repository.list(discoveredBackups: [remote])
        XCTAssertEqual(listed, [remote])
    }

    func testRetentionKeepsOtherDevicesAndNewestThirtyOwnBackups() async throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("workouts.sqlite")
        let cloud = folder.appendingPathComponent("Cloud", isDirectory: true)
        try WorkoutDatabase(url: url).save(snapshot())
        let repository = CloudBackupRepository(directoryProvider: { cloud })
        let deviceID = UUID().uuidString
        var own: [CloudBackup] = []
        let other = try await repository.createBackup(databaseURL: url, deviceID: UUID().uuidString)
        for _ in 0..<32 { own.append(try await repository.createBackup(databaseURL: url, deviceID: deviceID)) }
        try await repository.prune(deviceID: deviceID)
        let retained = try await repository.list()
        XCTAssertEqual(retained.count, 31)
        XCTAssertTrue(retained.contains { $0.url == other.url })
        XCTAssertFalse(retained.contains { $0.url == own[0].url || $0.url == own[1].url })
        XCTAssertTrue(retained.contains { $0.url == own.last?.url })
    }
}
