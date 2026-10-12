import Foundation

enum WorkoutHistoryDateRange: String, CaseIterable, Identifiable {
    case all, week, month, threeMonths

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All time"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .threeMonths: "Last 90 days"
        }
    }

    func startDate(relativeTo now: Date, calendar: Calendar) -> Date? {
        let days: Int
        switch self {
        case .all: return nil
        case .week: days = 7
        case .month: days = 30
        case .threeMonths: days = 90
        }
        return calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))
    }
}

enum WorkoutHistorySort: String, CaseIterable, Identifiable {
    case newest, oldest, nameAscending, nameDescending

    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .nameAscending: "Name A–Z"
        case .nameDescending: "Name Z–A"
        }
    }
}

enum WorkoutHistoryTemplateFilter: Hashable {
    case all, other, template(UUID)
}

struct WorkoutHistoryTemplateOption: Identifiable {
    let id: UUID
    let name: String

    /// Use recorded identities and the most recent name, including deleted templates.
    static func options(in workouts: [WorkoutSession]) -> [Self] {
        var latest: [UUID: WorkoutSession] = [:]
        for workout in workouts {
            guard let id = workout.templateID else { continue }
            if let previous = latest[id],
               previous.startedAt > workout.startedAt ||
                (previous.startedAt == workout.startedAt && previous.id.uuidString < workout.id.uuidString) {
                continue
            }
            latest[id] = workout
        }
        return latest.map { Self(id: $0.key, name: $0.value.name) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}

/// A view-only query: filtering and ordering never change saved history.
struct WorkoutHistoryQuery {
    var searchText = ""
    var dateRange = WorkoutHistoryDateRange.all
    var template = WorkoutHistoryTemplateFilter.all
    var sort = WorkoutHistorySort.newest

    var hasFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dateRange != .all || template != .all
    }

    mutating func clearFilters() {
        searchText = ""
        dateRange = .all
        template = .all
    }

    func results(in workouts: [WorkoutSession], now: Date = Date(), calendar: Calendar = .current) -> [WorkoutSession] {
        let terms = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        let start = dateRange.startDate(relativeTo: now, calendar: calendar)
        return workouts.filter { workout in
            if let start, workout.startedAt < start || workout.startedAt > now { return false }
            switch template {
            case .all: break
            case .other: if workout.templateID != nil { return false }
            case .template(let id): if workout.templateID != id { return false }
            }
            let names = [workout.name] + workout.exercises.map(\.exercise.name)
            return terms.allSatisfy { term in names.contains { $0.localizedStandardContains(term) } }
        }.sorted { lhs, rhs in
            switch sort {
            case .newest, .oldest:
                if lhs.startedAt != rhs.startedAt {
                    return sort == .newest ? lhs.startedAt > rhs.startedAt : lhs.startedAt < rhs.startedAt
                }
            case .nameAscending, .nameDescending:
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order != .orderedSame {
                    return sort == .nameAscending ? order == .orderedAscending : order == .orderedDescending
                }
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
