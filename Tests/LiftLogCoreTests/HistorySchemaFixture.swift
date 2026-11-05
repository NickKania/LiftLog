import Foundation
@testable import LiftLogCore

extension SQLiteConnection {
    /// Remove the latest feature before constructing a genuinely older database layout.
    func removeHistoryEditingSchema() throws {
        try execute("ALTER TABLE records DROP COLUMN summary")
        try execute("ALTER TABLE exercise_entries DROP COLUMN rest_seconds")
        try execute("DROP TABLE history_recovery")
        try execute("ALTER TABLE records DROP COLUMN notes")
        try execute("ALTER TABLE exercise_entries DROP COLUMN notes")
    }
}
