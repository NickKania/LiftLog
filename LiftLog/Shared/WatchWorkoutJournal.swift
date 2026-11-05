import Foundation

/// Watch-local recovery of the authoritative base and edits awaiting phone receipts.
/// Transport delivery never retires an edit. This is not a second workout database.
struct WatchWorkoutJournal {
    let url: URL

    private struct Archive: Codable {
        let version: Int
        let reconciler: WatchWorkoutReconciler
    }

    enum JournalError: Error {
        case unsupportedVersion
    }

    func load() throws -> WatchWorkoutReconciler? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1 else { throw JournalError.unsupportedVersion }
        return archive.reconciler
    }

    func save(_ reconciler: WatchWorkoutReconciler) throws {
        let data = try JSONEncoder().encode(Archive(version: 1, reconciler: reconciler))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
