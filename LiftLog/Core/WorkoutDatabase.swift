import Foundation

/// Relational storage for workout records, ordered exercise snapshots, sets, and preferences.
struct WorkoutDatabase {
    let url: URL
    private static let applicationID = 0x4C4C4F47 // LLOG

    func load(recoverInterruptedWrite: Bool = false) throws -> WorkoutSnapshot {
        // The working database needs write access for SQLite to roll back a hot journal
        // after process termination. Imported snapshots are inspected read-only.
        let db = try SQLiteConnection(url: url, readOnly: !recoverInterruptedWrite, create: false)
        return try db.readTransaction {
            let schemaVersion = try checkFormat(db)
            guard try db.rows("PRAGMA quick_check").first?.text("quick_check") == "ok",
                  try db.rows("PRAGMA foreign_key_check").isEmpty else {
                throw DatabaseError(message: "The workout database failed its integrity check.")
            }
            guard let settings = try db.rows("SELECT unit FROM settings WHERE id = 1").first,
                  let unit = WeightUnit(rawValue: try settings.text("unit")) else {
                throw DatabaseError(message: "The workout database is missing its weight preference.")
            }
            var snapshot = WorkoutSnapshot(templates: [], history: [], activeWorkout: nil, unit: unit)
            for row in try db.rows("SELECT * FROM records ORDER BY position") {
                let key = try row.text("record_key")
                let id = try row.uuid("id")
                let name = try row.text("name")
                let entries = try db.rows("SELECT * FROM exercise_entries WHERE record_key = ? ORDER BY position", [.text(key)])
                switch try row.text("kind") {
                case "template":
                    let exercises = try entries.map { entry -> TemplateExercise in
                        let sets = try setRows(db, key: key, entry: entry).map { set in
                            TemplateSet(id: try set.uuid("id"), weight: try set.number("weight"), targetReps: try set.integer("target_reps"))
                        }
                        return TemplateExercise(id: try entry.uuid("id"), exercise: try exercise(entry), sets: sets)
                    }
                    let versions: [WorkoutTemplateVersion]
                    if schemaVersion >= 2 {
                        versions = try db.rows("SELECT * FROM template_versions WHERE record_key = ? ORDER BY number", [.text(key)]).map { row in
                            let version = try JSONDecoder().decode(WorkoutTemplateVersion.self, from: Data(try row.text("payload").utf8))
                            guard version.id == (try row.uuid("id")), version.number == (try row.integer("number")) else {
                                throw DatabaseError(message: "A saved template version has inconsistent identifiers.")
                            }
                            return version
                        }
                    } else { versions = [] }
                    snapshot.templates.append(WorkoutTemplate(id: id, name: name, exercises: exercises, restSeconds: schemaVersion >= 3 ? try row.integer("rest_seconds") : 120, versions: versions))
                case "active", "history":
                    guard let recordedUnit = WeightUnit(rawValue: try row.text("unit")) else {
                        throw DatabaseError(message: "A workout has an invalid weight unit.")
                    }
                    let exercises = try entries.map { entry -> WorkoutExercise in
                        let sets = try setRows(db, key: key, entry: entry).map { set in
                            WorkoutSet(id: try set.uuid("id"), weight: try set.number("weight"), reps: try set.integer("reps"),
                                       targetReps: try set.optional("target_reps", read: set.integer),
                                       targetWeight: schemaVersion >= 2 ? try set.optional("target_weight", read: set.number) : nil,
                                       isCompleted: try set.integer("completed") == 1)
                        }
                        return WorkoutExercise(id: try entry.uuid("id"), exercise: try exercise(entry), sets: sets)
                    }
                    let session = WorkoutSession(
                        id: id, templateID: try row.optional("template_id", read: row.uuid),
                        templateVersionID: schemaVersion >= 2 ? try row.optional("template_version_id", read: row.uuid) : nil,
                        templateVersionNumber: schemaVersion >= 2 ? try row.optional("template_version_number", read: row.integer) : nil,
                        name: name,
                        startedAt: Date(timeIntervalSinceReferenceDate: try row.number("started_at")),
                        finishedAt: try row.optional("finished_at") { Date(timeIntervalSinceReferenceDate: try row.number($0)) },
                        unit: recordedUnit, importSourceKey: try row.optional("import_source_key", read: row.text), exercises: exercises,
                        restSeconds: schemaVersion >= 3 ? try row.integer("rest_seconds") : 120,
                        restTimer: schemaVersion >= 3 ? try row.optional("rest_timer") { try JSONDecoder().decode(WorkoutRestTimer.self, from: Data(row.text($0).utf8)) } : nil
                    )
                    if try row.text("kind") == "active" { snapshot.activeWorkout = session }
                    else { snapshot.history.append(session) }
                default: throw DatabaseError(message: "Unknown workout record type.")
                }
            }
            snapshot.personalExercises = try db.rows("SELECT * FROM personal_exercises ORDER BY position").map {
                Exercise(id: try $0.uuid("id"), name: try $0.text("name"), category: try $0.text("category"))
            }
            try WorkoutStore.validate(snapshot)
            return snapshot
        }
    }

    func save(_ snapshot: WorkoutSnapshot) throws {
        try WorkoutStore.validate(snapshot)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = manager.fileExists(atPath: url.path)
        do {
            let db = try SQLiteConnection(url: url)
            let schemaVersion = existed ? try checkFormat(db) : 1
            try db.transaction {
                if !existed { try createSchema(db) }
                if schemaVersion == 1 { try migrateVersionTwo(db) }
                if schemaVersion <= 2 { try migrateVersionThree(db) }
                try db.execute("DELETE FROM records")
                try db.execute("DELETE FROM personal_exercises")
                try db.execute("INSERT OR REPLACE INTO settings (id, unit) VALUES (1, ?)", [.text(snapshot.unit.rawValue)])
                for (position, template) in snapshot.templates.enumerated() {
                    let key = "template:\(template.id.uuidString)"
                    try db.execute("INSERT INTO records (record_key, id, kind, position, name, rest_seconds) VALUES (?, ?, 'template', ?, ?, ?)",
                                   [.text(key), .text(template.id.uuidString), .integer(Int64(position)), .text(template.name), .integer(Int64(template.restSeconds))])
                    for version in template.versions {
                        let payload = String(decoding: try JSONEncoder().encode(version), as: UTF8.self)
                        try db.execute("INSERT INTO template_versions (record_key, id, number, payload) VALUES (?, ?, ?, ?)",
                                       [.text(key), .text(version.id.uuidString), .integer(Int64(version.number)), .text(payload)])
                    }
                    for (position, entry) in template.exercises.enumerated() {
                        try saveEntry(db, key: key, id: entry.id, exercise: entry.exercise, position: position)
                        for (position, set) in entry.sets.enumerated() {
                            try saveSet(db, key: key, entryID: entry.id, id: set.id, position: position, weight: set.weight,
                                        reps: nil, targetReps: set.targetReps, targetWeight: nil, completed: false)
                        }
                    }
                }
                for (position, session) in snapshot.history.enumerated() {
                    try saveSession(db, session: session, kind: "history", position: position)
                }
                if let active = snapshot.activeWorkout { try saveSession(db, session: active, kind: "active", position: 0) }
                for (position, exercise) in snapshot.personalExercises.enumerated() {
                    try db.execute("INSERT INTO personal_exercises (id, position, name, category) VALUES (?, ?, ?, ?)",
                                   [.text(exercise.id.uuidString), .integer(Int64(position)), .text(exercise.name), .text(exercise.category)])
                }
            }
        } catch {
            // A failed first save must not leave an empty database that blocks migration next launch.
            if !existed { try? manager.removeItem(at: url) }
            throw error
        }
    }

    func backup(to destination: URL) throws {
        guard destination.standardizedFileURL != url.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw DatabaseError(message: "Choose a new file for the database backup.")
        }
        let source = try SQLiteConnection(url: url, readOnly: true)
        _ = try checkFormat(source)
        do {
            let target = try SQLiteConnection(url: destination)
            try source.backup(to: target)
            // The source may use WAL. Cloud snapshots must be readable as one file,
            // without requiring a writable directory for journal sidecars.
            _ = try target.rows("PRAGMA journal_mode = DELETE")
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func checkFormat(_ db: SQLiteConnection) throws -> Int {
        let version = try db.rows("PRAGMA user_version").first?.integer("user_version")
        guard try db.rows("PRAGMA application_id").first?.integer("application_id") == Self.applicationID,
              let version, (1...3).contains(version) else {
            throw DatabaseError(message: "This file is not a supported Lift Log database.")
        }
        return version
    }

    /// Schema and data are upgraded inside the same transaction as the first v2 save.
    private func migrateVersionTwo(_ db: SQLiteConnection) throws {
        let statements = [
            "ALTER TABLE records ADD COLUMN template_version_id TEXT",
            "ALTER TABLE records ADD COLUMN template_version_number INTEGER CHECK (template_version_number > 0)",
            "ALTER TABLE workout_sets ADD COLUMN target_weight REAL CHECK (target_weight >= 0)",
            """
            CREATE TABLE template_versions (
                record_key TEXT NOT NULL REFERENCES records(record_key) ON DELETE CASCADE,
                id TEXT NOT NULL UNIQUE, number INTEGER NOT NULL CHECK (number > 0), payload TEXT NOT NULL,
                PRIMARY KEY (record_key, number)
            )
            """,
            "PRAGMA user_version = 2"
        ]
        for statement in statements { try db.execute(statement) }
    }

    /// Read-only old backups remain readable; only a successful save upgrades their schema.
    private func migrateVersionThree(_ db: SQLiteConnection) throws {
        try db.execute("ALTER TABLE records ADD COLUMN rest_seconds INTEGER NOT NULL DEFAULT 120 CHECK (rest_seconds BETWEEN 0 AND 3600)")
        try db.execute("ALTER TABLE records ADD COLUMN rest_timer TEXT")
        try db.execute("PRAGMA user_version = 3")
    }

    private func createSchema(_ db: SQLiteConnection) throws {
        let statements = [
            "PRAGMA application_id = \(Self.applicationID)",
            "PRAGMA user_version = 1",
            "CREATE TABLE settings (id INTEGER PRIMARY KEY CHECK (id = 1), unit TEXT NOT NULL CHECK (unit IN ('lb', 'kg')))",
            """
            CREATE TABLE records (
                record_key TEXT PRIMARY KEY NOT NULL, id TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('template', 'active', 'history')),
                position INTEGER NOT NULL, name TEXT NOT NULL, template_id TEXT,
                started_at REAL, finished_at REAL, unit TEXT CHECK (unit IN ('lb', 'kg')), import_source_key TEXT,
                UNIQUE (kind, id), UNIQUE (kind, position),
                CHECK (kind = 'template' OR (started_at IS NOT NULL AND unit IS NOT NULL)),
                CHECK (kind != 'active' OR finished_at IS NULL),
                CHECK (kind != 'history' OR finished_at IS NOT NULL)
            )
            """,
            "CREATE UNIQUE INDEX single_active_workout ON records (kind) WHERE kind = 'active'",
            """
            CREATE TABLE exercise_entries (
                record_key TEXT NOT NULL REFERENCES records(record_key) ON DELETE CASCADE,
                id TEXT NOT NULL, position INTEGER NOT NULL, exercise_id TEXT NOT NULL,
                exercise_name TEXT NOT NULL, exercise_category TEXT NOT NULL,
                PRIMARY KEY (record_key, id), UNIQUE (record_key, position)
            )
            """,
            """
            CREATE TABLE workout_sets (
                record_key TEXT NOT NULL, entry_id TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL,
                weight REAL NOT NULL CHECK (weight >= 0), reps INTEGER CHECK (reps > 0),
                target_reps INTEGER CHECK (target_reps > 0), completed INTEGER NOT NULL CHECK (completed IN (0, 1)),
                PRIMARY KEY (record_key, entry_id, id), UNIQUE (record_key, entry_id, position),
                FOREIGN KEY (record_key, entry_id) REFERENCES exercise_entries(record_key, id) ON DELETE CASCADE,
                CHECK (reps IS NOT NULL OR target_reps IS NOT NULL)
            )
            """,
            "CREATE TABLE personal_exercises (id TEXT PRIMARY KEY NOT NULL, position INTEGER UNIQUE NOT NULL, name TEXT NOT NULL, category TEXT NOT NULL)"
        ]
        for statement in statements { try db.execute(statement) }
    }

    private func exercise(_ row: SQLiteRow) throws -> Exercise {
        Exercise(id: try row.uuid("exercise_id"), name: try row.text("exercise_name"), category: try row.text("exercise_category"))
    }

    private func setRows(_ db: SQLiteConnection, key: String, entry: SQLiteRow) throws -> [SQLiteRow] {
        try db.rows("SELECT * FROM workout_sets WHERE record_key = ? AND entry_id = ? ORDER BY position", [.text(key), .text(try entry.text("id"))])
    }

    private func saveSession(_ db: SQLiteConnection, session: WorkoutSession, kind: String, position: Int) throws {
        let key = "session:\(session.id.uuidString)"
        try db.execute("""
            INSERT INTO records (record_key, id, kind, position, name, template_id, started_at, finished_at, unit, import_source_key, template_version_id, template_version_number, rest_seconds, rest_timer)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(key), .text(session.id.uuidString), .text(kind), .integer(Int64(position)), .text(session.name),
                  .optional(session.templateID?.uuidString), .date(session.startedAt), .date(session.finishedAt),
                  .text(session.unit.rawValue), .optional(session.importSourceKey), .optional(session.templateVersionID?.uuidString), .optional(session.templateVersionNumber), .integer(Int64(session.restSeconds)),
                  .optional(try session.restTimer.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) })])
        for (position, entry) in session.exercises.enumerated() {
            try saveEntry(db, key: key, id: entry.id, exercise: entry.exercise, position: position)
            for (position, set) in entry.sets.enumerated() {
                try saveSet(db, key: key, entryID: entry.id, id: set.id, position: position, weight: set.weight,
                            reps: set.reps, targetReps: set.targetReps, targetWeight: set.targetWeight, completed: set.isCompleted)
            }
        }
    }

    private func saveEntry(_ db: SQLiteConnection, key: String, id: UUID, exercise: Exercise, position: Int) throws {
        try db.execute("INSERT INTO exercise_entries (record_key, id, position, exercise_id, exercise_name, exercise_category) VALUES (?, ?, ?, ?, ?, ?)",
                       [.text(key), .text(id.uuidString), .integer(Int64(position)), .text(exercise.id.uuidString), .text(exercise.name), .text(exercise.category)])
    }

    private func saveSet(_ db: SQLiteConnection, key: String, entryID: UUID, id: UUID, position: Int, weight: Double, reps: Int?, targetReps: Int?, targetWeight: Double?, completed: Bool) throws {
        try db.execute("INSERT INTO workout_sets (record_key, entry_id, id, position, weight, reps, target_reps, completed, target_weight) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       [.text(key), .text(entryID.uuidString), .text(id.uuidString), .integer(Int64(position)), .real(weight),
                        .optional(reps), .optional(targetReps), .integer(completed ? 1 : 0), targetWeight.map(SQLiteValue.real) ?? .null])
    }
}
