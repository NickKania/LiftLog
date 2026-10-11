import SwiftUI

struct HealthDashboardView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var section = Section.consistency
    @State private var range = HealthDashboardRange.threeMonths

    private enum Section: String, CaseIterable, Identifiable {
        case consistency = "Consistency"
        case weight = "Weight"
        case activity = "Activity"
        var id: String { rawValue }
        var description: String {
            switch self {
            case .consistency: "See the rhythm of your training."
            case .weight: "Follow the weights you lift, exercise by exercise."
            case .activity: "Explore workout time and available Apple Health readings."
            }
        }
    }

    private var analytics: HealthDashboardAnalytics {
        HealthDashboardAnalytics(workouts: store.history, unit: store.unit, range: range)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    sectionPicker

                    HStack(alignment: .center) {
                        Text("YOUR TRAINING")
                            .font(.caption.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Picker("Date range", selection: $range) {
                                ForEach(HealthDashboardRange.allCases) { Text($0.label).tag($0) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar")
                                Text(range.label)
                                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.blue.opacity(0.08), in: Capsule())
                        }
                        .accessibilityLabel("Date range, \(range.label)")
                        .accessibilityIdentifier("healthDateRangePicker")
                    }
                    Text(section.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if analytics.workoutCount == 0 {
                    emptyState
                } else {
                    switch section {
                    case .consistency:
                        HealthDashboardConsistencyView(analytics: analytics)
                    case .weight:
                        HealthDashboardWeightView(analytics: analytics, unit: store.unit)
                    case .activity:
                        HealthDashboardActivityView(workouts: analytics.workouts, range: range)
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Health")
        .accessibilityIdentifier("healthDashboard")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            ContentUnavailableView(
                store.history.isEmpty ? "Your training story starts here" : "No workouts in this range",
                systemImage: "chart.bar.xaxis",
                description: Text(store.history.isEmpty
                    ? "Finish a workout to see your consistency, lifting progress, and activity."
                    : "Choose a longer date range to explore your recorded workouts.")
            )
            if !store.history.isEmpty && range != .all {
                Button("Show All Workouts") { range = .all }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var sectionPicker: some View {
        let picker = Picker("Health section", selection: $section) {
            ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
        }
        .accessibilityIdentifier("healthSectionPicker")
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
        }
    }
}

struct HealthDashboardCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    private let content: Content

    init(title: String, subtitle: String? = nil, systemImage: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage).foregroundStyle(.teal).accessibilityHidden(true)
                    }
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct HealthDashboardMetric: View {
    let title: String
    let value: String
    var detail: String? = nil
    var tint: Color = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

struct HealthDashboardInsight: View {
    let text: String
    var systemImage: String = "sparkles"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.teal).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum HealthDashboardFormatting {
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return "Unavailable" }
        let minutes = Int(interval / 60)
        if minutes == 0 { return "\(Int(interval)) sec" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }
}
