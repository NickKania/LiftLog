import SwiftUI

struct CloudBackupSettingsView: View {
    @Environment(WorkoutStore.self) private var store
    @State private var selectedBackup: CloudBackup?

    private var backup: CloudBackupManager { store.cloudBackup }

    var body: some View {
        Section {
            Toggle("Automatic iCloud Backups", isOn: Binding(
                get: { backup.automaticBackupsEnabled },
                set: { backup.setAutomaticBackups($0) }
            ))
            .accessibilityIdentifier("automaticCloudBackupsToggle")
            .disabled(!backup.available || backup.isWorking)

            Button {
                Task { await backup.backUpNow() }
            } label: {
                Label("Back Up Now", systemImage: "icloud.and.arrow.up")
            }
            .accessibilityIdentifier("backUpNowButton")
            .disabled(!backup.available || backup.isWorking)

            NavigationLink {
                backupList
            } label: {
                Label("Restore from Backup", systemImage: "icloud.and.arrow.down")
            }
            .accessibilityIdentifier("restoreBackupButton")
            .disabled(!backup.available || store.isRestoring)

            if let date = backup.lastBackupDate {
                LabeledContent("Last backup saved") { Text(date, format: .dateTime.month().day().hour().minute()) }
            }
            if backup.isWorking { ProgressView("Working with iCloud Drive…") }
            if let message = backup.statusMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = backup.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("iCloud Drive Backups")
        } footer: {
            Text("Backups include templates, personal exercises, settings, history, and your active workout. Automatic backups run after changes and when you leave the app. Your workouts stay available offline. Keep iCloud Drive enabled in iPhone Settings.")
        }
    }

    private var backupList: some View {
        List {
            Section {
                Button("Refresh Backups", systemImage: "arrow.clockwise") {
                    Task { await backup.refresh() }
                }
                .disabled(backup.isWorking)
                if backup.isWorking { ProgressView("Working with iCloud Drive…") }
                if let error = backup.errorMessage { Text(error).foregroundStyle(.red) }
                if let message = backup.statusMessage { Text(message).foregroundStyle(.secondary) }
            }
            Section {
                if backup.backups.isEmpty && !backup.isWorking {
                    Text("No backups found in iCloud Drive.").foregroundStyle(.secondary)
                }
                ForEach(backup.backups) { item in
                    Button { selectedBackup = item } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.date, format: .dateTime.year().month().day().hour().minute().second())
                                .foregroundStyle(.primary)
                            Text("\(item.uploadStatus) · \(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(backup.isWorking)
                }
            } header: {
                Text("Saved Backups")
            } footer: {
                Text("Restoring replaces all data on this device with the selected backup. A local recovery copy is saved first. Each device keeps its newest 30 uploaded backups; pending uploads are retained. You can also manage backup files in iCloud Drive → Lift Log → Backups.")
            }
        }
        .navigationTitle("Restore Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await backup.refresh() }
        .confirmationDialog("Replace your current workout data?", isPresented: Binding(
            get: { selectedBackup != nil }, set: { if !$0 { selectedBackup = nil } }
        ), titleVisibility: .visible) {
            Button("Restore Backup", role: .destructive) {
                if let selectedBackup {
                    Task { await backup.restore(selectedBackup, into: store) }
                }
                selectedBackup = nil
            }
        } message: {
            if let selectedBackup {
                Text("Restore the backup from \(selectedBackup.date.formatted(date: .abbreviated, time: .shortened)). Your current data will be kept in a local recovery file.")
            }
        }
    }
}
