import Foundation
import SQLite3

struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SQLiteValue {
    case text(String), integer(Int64), real(Double), null

    static func optional(_ value: String?) -> SQLiteValue { value.map(Self.text) ?? .null }
    static func optional(_ value: Int?) -> SQLiteValue { value.map { .integer(Int64($0)) } ?? .null }
    static func date(_ value: Date?) -> SQLiteValue { value.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null }
}

struct SQLiteRow {
    let values: [String: SQLiteValue]

    func text(_ key: String) throws -> String {
        guard case .text(let value) = values[key] else { throw invalid(key) }
        return value
    }

    func integer(_ key: String) throws -> Int {
        guard case .integer(let value) = values[key], let result = Int(exactly: value) else { throw invalid(key) }
        return result
    }

    func number(_ key: String) throws -> Double {
        switch values[key] {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: throw invalid(key)
        }
    }

    func uuid(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try text(key)) else { throw invalid(key) }
        return value
    }

    func optional<T>(_ key: String, read: (String) throws -> T) throws -> T? {
        if case .null = values[key] { return nil }
        return try read(key)
    }

    private func invalid(_ key: String) -> DatabaseError {
        DatabaseError(message: "The workout database contains an invalid \(key) value.")
    }
}

/// Connections stay within one synchronous operation; cloud work uses its own connection.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool = false, create: Bool = true) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let error = failure()
            sqlite3_close(handle)
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 3000)
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func rows(_ sql: String, _ values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            var row: [String: SQLiteValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_TEXT:
                    // Preserve embedded NUL characters by using SQLite's byte count.
                    let count = Int(sqlite3_column_bytes(statement, column))
                    let bytes = UnsafeBufferPointer(start: sqlite3_column_text(statement, column), count: count)
                    row[name] = .text(String(decoding: bytes, as: UTF8.self))
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_NULL: row[name] = .null
                default: throw DatabaseError(message: "Unexpected binary data in the workout database.")
                }
            }
            rows.append(SQLiteRow(values: row))
        }
    }

    func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func readTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// SQLite's backup API captures a consistent database, including any journaled pages.
    func backup(to destination: SQLiteConnection) throws {
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw destination.failure()
        }
        var result: Int32 = SQLITE_OK
        var retries = 0
        repeat {
            result = sqlite3_backup_step(backup, -1)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                retries += 1
                sqlite3_sleep(50)
            }
        } while (result == SQLITE_BUSY || result == SQLITE_LOCKED) && retries < 60
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw destination.failure() }
    }

    private func prepare(_ sql: String, _ values: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        do {
            guard sqlite3_bind_parameter_count(statement) == Int32(values.count) else {
                throw DatabaseError(message: "Incorrect database parameter count.")
            }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .text(let text):
                    result = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                case .integer(let integer): result = sqlite3_bind_int64(statement, index, integer)
                case .real(let number): result = sqlite3_bind_double(statement, index, number)
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw failure() }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func failure() -> DatabaseError {
        DatabaseError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the workout database.")
    }
}
