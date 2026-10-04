import Foundation

struct CloudBackup: Identifiable, Equatable {
    let url: URL
    let date: Date
    let byteCount: Int64
    let uploadStatus: String
    var id: URL { url }
}

/// All iCloud filesystem access and SQLite snapshot creation run away from the main actor.
actor CloudBackupRepository {
    static let containerIdentifier = "iCloud.com.liftlog.app"
    let usesICloud: Bool
    private let directoryProvider: @Sendable () throws -> URL

    init(directoryProvider: (@Sendable () throws -> URL)? = nil) {
        usesICloud = directoryProvider == nil
        self.directoryProvider = directoryProvider ?? {
            let manager = FileManager.default
            guard manager.ubiquityIdentityToken != nil,
                  let container = manager.url(forUbiquityContainerIdentifier: Self.containerIdentifier) else {
                throw DatabaseError(message: "iCloud Drive is unavailable. Sign in to iCloud, enable iCloud Drive for Lift Log, and try again.")
            }
            return container.appendingPathComponent("Documents/Backups", isDirectory: true)
        }
    }

    func directory() throws -> URL {
        let url = try directoryProvider().resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func createBackup(databaseURL: URL, deviceID: String) throws -> CloudBackup {
        let folder = try directory()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }
        try WorkoutDatabase(url: databaseURL).backup(to: staging)
        try WorkoutStore.validate(WorkoutDatabase(url: staging).load())
        let date = Date()
        let filename = "LiftLog-\(Int64(date.timeIntervalSince1970 * 1000))-\(deviceID)-\(UUID().uuidString).sqlite"
        let target = folder.appendingPathComponent(filename)
        let data = try Data(contentsOf: staging)
        try coordinatedWrite(target) { try data.write(to: $0, options: .atomic) }
        return try describe(target)
    }

    func list(discoveredBackups: [CloudBackup] = []) throws -> [CloudBackup] {
        let folder = try directory()
        var backups: [URL: CloudBackup] = [:]
        // Metadata descriptors can represent files that have no downloaded local contents yet.
        for backup in discoveredBackups where backup.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            backups[backup.url] = backup
        }
        let local = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for url in local where url.lastPathComponent.hasPrefix("LiftLog-") && url.pathExtension == "sqlite" {
            if let backup = try? describe(url) { backups[backup.url] = backup }
        }
        return backups.values.sorted { $0.date > $1.date }
    }

    /// Download placeholders first, then coordinate a read into an isolated local file.
    func download(_ backup: CloudBackup) async throws -> URL {
        let folder = try directory()
        guard backup.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
            throw DatabaseError(message: "The selected backup is outside the Lift Log backup folder.")
        }
        if usesICloud {
            try FileManager.default.startDownloadingUbiquitousItem(at: backup.url)
            let deadline = Date().addingTimeInterval(30)
            while true {
                try Task.checkCancellation()
                let values = try backup.url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
                if let error = values.ubiquitousItemDownloadingError { throw error }
                if values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded { break }
                guard Date() < deadline else {
                    throw DatabaseError(message: "This backup is still downloading from iCloud. Check your connection and try again.")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).sqlite")
        do {
            try coordinatedRead(backup.url) { try FileManager.default.copyItem(at: $0, to: staging) }
            return staging
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Retain pending uploads and the newest 30 uploaded snapshots from this installation.
    func prune(deviceID: String) throws {
        let own = try list().filter {
            $0.url.lastPathComponent.contains("-\(deviceID)-")
                && (!usesICloud || $0.uploadStatus == "Uploaded to iCloud")
        }
        for old in own.dropFirst(30) {
            try coordinatedWrite(old.url, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
        }
    }

    private func describe(_ itemURL: URL) throws -> CloudBackup {
        // Directory listings may return URLs relative to a base URL. Use one stable identity.
        let url = URL(fileURLWithPath: itemURL.resolvingSymlinksInPath().path)
        let keys: Set<URLResourceKey> = [.creationDateKey, .fileSizeKey, .isRegularFileKey,
                                        .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true else { throw DatabaseError(message: "A backup is not a regular file.") }
        let milliseconds = url.lastPathComponent.split(separator: "-").dropFirst().first.flatMap { Double($0) }
        let date = milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) } ?? values.creationDate ?? .distantPast
        let status: String
        if values.ubiquitousItemUploadingError != nil { status = "Upload failed" }
        else if values.ubiquitousItemIsUploaded == true { status = "Uploaded to iCloud" }
        else if values.ubiquitousItemIsUploading == true { status = "Uploading to iCloud" }
        else { status = usesICloud ? "Waiting for iCloud upload" : "Saved" }
        return CloudBackup(url: url, date: date, byteCount: Int64(values.fileSize ?? 0), uploadStatus: status)
    }

    private func coordinatedRead(_ url: URL, operation: (URL) throws -> Void) throws {
        var coordinatorError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) {
            do { try operation($0) } catch { operationError = error }
        }
        if let error = coordinatorError ?? operationError { throw error }
    }

    private func coordinatedWrite(_ url: URL, options: NSFileCoordinator.WritingOptions = [], operation: (URL) throws -> Void) throws {
        var coordinatorError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinatorError) {
            do { try operation($0) } catch { operationError = error }
        }
        if let error = coordinatorError ?? operationError { throw error }
    }
}
