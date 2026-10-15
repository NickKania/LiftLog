import SwiftUI

struct CatalogCreditsView: View {
    private let sources = ExerciseCatalog.attribution.sources

    var body: some View {
        List {
            Section {
                Text("Catalog credits and license notices are included with Lift Log and available offline.")
                    .accessibilityIdentifier("catalogCreditsOfflineNotice")
            }
            ForEach(sources, id: \.id) { source in
                Section {
                    Text(source.name)
                        .font(.headline)
                        .accessibilityIdentifier("catalogCreditSource-\(source.id)")
                    Text(source.credit)
                    detail("Author / maintainer", value: source.author)
                    detail("Declared license", value: source.licenseID)
                    Text(source.licenseScope)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("catalogLicenseScope-\(source.id)")
                    NavigationLink {
                        CatalogLicenseView(source: source)
                    } label: {
                        Label("Read Full License", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("catalogFullLicenseLink-\(source.id)")
                } header: {
                    Text("Exercise catalog")
                }
                Section("Source snapshot") {
                    detail("Repository", value: source.repositoryURL.absoluteString)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pinned revision").font(.subheadline).foregroundStyle(.secondary)
                        Text(source.revision)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("catalogSourceRevision-\(source.id)")
                    }
                    .padding(.vertical, 4)
                }
                Section("Content review") {
                    Text(reviewLabel(source.reviewStatus))
                        .font(.headline)
                        .accessibilityIdentifier("catalogReviewStatus-\(source.id)")
                    Text(source.reviewNote)
                        .accessibilityIdentifier("catalogReviewNote-\(source.id)")
                }
                if !source.excludedContent.isEmpty {
                    Section("Excluded content") {
                        Text(source.excludedContent.joined(separator: "\n\n"))
                            .accessibilityIdentifier("catalogExcludedContent-\(source.id)")
                    }
                }
                if !source.modifications.isEmpty {
                    Section("Changes in Lift Log") {
                        ForEach(source.modifications, id: \.self) { modification in
                            Text(modification)
                        }
                    }
                }
            }
        }
        .navigationTitle("Credits & Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func reviewLabel(_ status: String) -> String {
        switch status {
        case "pendingReview": return "Awaiting content review"
        case "reviewed": return "Reviewed"
        default: return status
        }
    }
}

private struct CatalogLicenseView: View {
    let source: ExerciseContentSource

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(source.name)
                    .font(.headline)
                Text(source.licenseScope)
                    .foregroundStyle(.secondary)
                Text(source.licenseText)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("catalogFullLicenseText-\(source.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(source.licenseID)
        .navigationBarTitleDisplayMode(.inline)
    }
}
