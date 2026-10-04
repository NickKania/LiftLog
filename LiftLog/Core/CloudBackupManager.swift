import Foundation
import Observation

@Observable @MainActor
final class CloudBackupManager {
    private(set) var automaticBackupsEnabled: Bool
    private(set) var backups: [CloudBackup] = []
    private(set) var isWorking = false
    private(set) var lastBackupDate: Date?
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    let available: Bool

    @ObservationIgnored private let databaseURL: URL
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let repository: CloudBackupRepository
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private var scheduledBackup: Task<Void, Never>?
    @ObservationIgnored private var needsBackup = false

    init(databaseURL: URL, available: Bool = true, repository: CloudBackupRepository = CloudBackupRepository(), preferences: UserDefaults = .standard) {
        self.databaseURL = databaseURL
        self.available = available
        self.repository = repository
        self.preferences = preferences
        automaticBackupsEnabled = available && preferences.bool(forKey: "automaticCloudBackups")
        lastBackupDate = preferences.object(forKey: "lastCloudBackupDate") as? Date
        if let saved = preferences.string(forKey: "cloudBackupDeviceID") { deviceID = saved }
        else {
            let id = UUID().uuidString
            deviceID = id
            if available { preferences.set(id, forKey: "cloudBackupDeviceID") }
        }
    }

    func setAutomaticBackups(_ enabled: Bool) {
        automaticBackupsEnabled = enabled && available
        if available { preferences.set(automaticBackupsEnabled, forKey: "automaticCloudBackups") }
        if automaticBackupsEnabled { scheduleBackup() }
        else {
            scheduledBackup?.cancel()
            scheduledBackup = nil
            needsBackup = false
        }
    }

    /// Debounce edits and limit automatic snapshots to one every 15 minutes.
    func scheduleBackup() {
        guard automaticBackupsEnabled else { return }
        needsBackup = true
        guard !isWorking else { return }
        scheduledBackup?.cancel()
        let delay = max(5, 15 * 60 - Date().timeIntervalSince(lastBackupDate ?? .distantPast))
        scheduledBackup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.scheduledBackup = nil
            await self.backUpNow()
        }
    }

    func backUpIfEnabled() async {
        guard automaticBackupsEnabled else { return }
        // A background activity must also cover a snapshot already in progress.
        while isWorking {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard automaticBackupsEnabled, needsBackup else { return }
        await backUpNow()
    }

    func backUpNow() async {
        guard available, !isWorking else { return }
        scheduledBackup?.cancel()
        scheduledBackup = nil
        isWorking = true
        needsBackup = false
        errorMessage = nil
        statusMessage = "Saving backup to iCloud Drive…"
        do {
            let backup = try await repository.createBackup(databaseURL: databaseURL, deviceID: deviceID)
            lastBackupDate = backup.date
            preferences.set(backup.date, forKey: "lastCloudBackupDate")
            statusMessage = "Backup saved to iCloud Drive. iCloud uploads it when a connection is available."
            // Retention failure must not misreport a successfully saved backup as failed.
            try? await repository.prune(deviceID: deviceID)
            if let listed = try? await repository.list() { backups = listed }
            else { backups = [backup] + backups.filter { $0.id != backup.id } }
        } catch {
            needsBackup = true
            statusMessage = nil
            errorMessage = "Could not back up your workouts: \(error.localizedDescription) Your workouts remain saved on this device."
        }
        isWorking = false
        // Retry after the next change or foreground transition rather than looping on an unavailable account.
        if needsBackup && errorMessage == nil { scheduleBackup() }
    }

    func refresh() async {
        guard available, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        do {
            let directory = try await repository.directory()
            let discovered = repository.usesICloud ? try await discoverBackups(in: directory) : []
            try? await repository.prune(deviceID: deviceID)
            backups = try await repository.list(discoveredBackups: discovered)
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
        if needsBackup { scheduleBackup() }
    }

    /// Store owns validation and replacement; manager owns download progress and cloud errors.
    func restore(_ backup: CloudBackup, into store: WorkoutStore) async {
        guard available, !isWorking else { return }
        scheduledBackup?.cancel()
        scheduledBackup = nil
        isWorking = true
        errorMessage = nil
        statusMessage = "Downloading and checking backup…"
        store.beginRestore()
        do {
            let staging = try await repository.download(backup)
            defer { try? FileManager.default.removeItem(at: staging) }
            try store.restoreDatabase(from: staging)
            statusMessage = "Backup restored. Your previous data was kept in a local recovery file."
        } catch {
            statusMessage = nil
            errorMessage = "Could not restore this backup: \(error.localizedDescription)"
        }
        store.endRestore()
        isWorking = false
        if needsBackup { scheduleBackup() }
    }

    /// A metadata query finds remote backups that have not been downloaded on this device.
    private func discoverBackups(in directory: URL) async throws -> [CloudBackup] {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@ AND %K ENDSWITH %@", NSMetadataItemFSNameKey, "LiftLog-", NSMetadataItemFSNameKey, ".sqlite")
        let state = MetadataGatheringState()
        let observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
            Task { @MainActor in state.finished = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        guard query.start() else { throw DatabaseError(message: "Could not search iCloud Drive for backups.") }
        defer { query.stop() }
        let deadline = Date().addingTimeInterval(10)
        while !state.finished {
            guard Date() < deadline else { throw DatabaseError(message: "iCloud is still finding backups. Try refreshing again shortly.") }
            try await Task.sleep(for: .milliseconds(250))
        }
        query.disableUpdates()
        return (0..<query.resultCount).compactMap { index -> CloudBackup? in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let itemURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { return nil }
            let url = URL(fileURLWithPath: itemURL.resolvingSymlinksInPath().path)
            guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return nil }
            let milliseconds = url.lastPathComponent.split(separator: "-").dropFirst().first.flatMap { Double($0) }
            let date = milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? .distantPast
            let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
            let status: String
            if item.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey) as? NSError != nil { status = "Upload failed" }
            else if item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool == true { status = "Uploaded to iCloud" }
            else if item.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool == true { status = "Uploading to iCloud" }
            else { status = "Waiting for iCloud upload" }
            return CloudBackup(url: url, date: date, byteCount: size, uploadStatus: status)
        }
    }
}

@MainActor
private final class MetadataGatheringState {
    var finished = false
}
