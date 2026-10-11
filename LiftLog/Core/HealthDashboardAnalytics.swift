import Foundation

enum HealthDashboardRange: String, CaseIterable, Identifiable {
    case month, threeMonths, year, all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .month: "Month"
        case .threeMonths: "3 months"
        case .year: "Year"
        case .all: "All time"
        }
    }

    func startDate(relativeTo now: Date, calendar: Calendar) -> Date? {
        let date: Date?
        switch self {
        case .month: date = calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: date = calendar.date(byAdding: .month, value: -3, to: now)
        case .year: date = calendar.date(byAdding: .year, value: -1, to: now)
        case .all: return nil
        }
        return date.map { calendar.startOfDay(for: $0) }
    }
}

struct HealthDashboardDay: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let count: Int
}

struct HealthDashboardWeekday: Identifiable, Equatable {
    var id: Int { weekday }
    let weekday: Int
    let label: String
    let count: Int
}

struct HealthDashboardDuration: Identifiable, Equatable {
    var id: UUID { workoutID }
    let workoutID: UUID
    let name: String
    let date: Date
    let duration: TimeInterval
}

struct HealthDashboardWeightPoint: Identifiable, Equatable {
    var id: UUID { workoutID }
    let workoutID: UUID
    let date: Date
    let weight: Double
    let reps: Int
}

/// One maximum completed-set load per session, expressed in the dashboard unit.
struct HealthDashboardExercise: Identifiable, Equatable {
    let id: UUID
    let name: String
    let points: [HealthDashboardWeightPoint]
    var maximumWeight: Double { points.map(\.weight).max() ?? 0 }
    var firstWeight: Double { points.first?.weight ?? 0 }
    var latestWeight: Double { points.last?.weight ?? 0 }
    var change: Double { latestWeight - firstWeight }
    var changePercent: Double? { firstWeight > 0 ? change / firstWeight * 100 : nil }
    var sessionCount: Int { points.count }
}

struct HealthDashboardRecord: Identifiable, Equatable {
    var id: UUID { exerciseID }
    let exerciseID: UUID
    let name: String
    let weight: Double
    let date: Date
    let reps: Int
}

struct HealthDashboardTemplateActivity: Identifiable, Equatable {
    let id: String
    let templateID: UUID?
    let name: String
    let workoutCount: Int
    let totalDuration: TimeInterval
    /// Mean of available session averages; sample density does not weight sessions.
    let averageHeartRate: Double?
    let activeEnergy: Double?
    let heartRateWorkoutCount: Int
    let energyWorkoutCount: Int
    var averageDuration: TimeInterval? { workoutCount > 0 ? totalDuration / Double(workoutCount) : nil }
}

struct HealthDashboardActivity: Equatable {
    let workoutCount: Int
    let totalDuration: TimeInterval
    let longestDuration: TimeInterval?
    let averageHeartRate: Double?
    let activeEnergy: Double?
    let heartRateWorkoutCount: Int
    let energyWorkoutCount: Int
    let templates: [HealthDashboardTemplateActivity]
    var averageDuration: TimeInterval? { workoutCount > 0 ? totalDuration / Double(workoutCount) : nil }
}

/// Derived dashboard data only. Reading this value never requests Apple Health access.
struct HealthDashboardAnalytics {
    let workouts: [WorkoutSession]
    let unit: WeightUnit
    let range: HealthDashboardRange
    let now: Date
    let calendar: Calendar

    init(workouts: [WorkoutSession], unit: WeightUnit, range: HealthDashboardRange,
         now: Date = Date(), calendar: Calendar = .current) {
        self.unit = unit
        self.range = range
        self.now = now
        self.calendar = calendar
        let lowerBound = now.timeIntervalSinceReferenceDate.isFinite
            ? range.startDate(relativeTo: now, calendar: calendar) : nil
        self.workouts = workouts.filter { workout in
            guard now.timeIntervalSinceReferenceDate.isFinite,
                  workout.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  let finish = workout.finishedAt,
                  finish.timeIntervalSinceReferenceDate.isFinite,
                  finish >= workout.startedAt, finish <= now,
                  workout.startedAt.timeIntervalSince(finish).isFinite else { return false }
            return lowerBound.map { workout.startedAt >= $0 } ?? true
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var workoutCount: Int { workouts.count }
    var activeDayCount: Int { Set(workouts.map { calendar.startOfDay(for: $0.startedAt) }).count }
    var durations: [HealthDashboardDuration] {
        workouts.compactMap { workout in
            guard let finish = workout.finishedAt else { return nil }
            return HealthDashboardDuration(workoutID: workout.id, name: workout.name,
                                           date: workout.startedAt, duration: finish.timeIntervalSince(workout.startedAt))
        }
    }
    var totalDuration: TimeInterval { durations.reduce(0) { $0 + $1.duration } }
    var averageDuration: TimeInterval? { workouts.isEmpty ? nil : totalDuration / Double(workoutCount) }
    var longestDuration: TimeInterval? { durations.map(\.duration).max() }

    var dailyCounts: [HealthDashboardDay] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let counts = Dictionary(grouping: workouts) { calendar.startOfDay(for: $0.startedAt) }.mapValues(\.count)
        let end = calendar.startOfDay(for: now)
        var day = range.startDate(relativeTo: now, calendar: calendar)
            ?? workouts.first.map { calendar.startOfDay(for: $0.startedAt) } ?? end
        var days: [HealthDashboardDay] = []
        while day <= end {
            days.append(HealthDashboardDay(date: day, count: counts[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return days
    }

    var weekdayCounts: [HealthDashboardWeekday] {
        let counts = Dictionary(grouping: workouts) { calendar.component(.weekday, from: $0.startedAt) }.mapValues(\.count)
        return (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return HealthDashboardWeekday(weekday: weekday, label: calendar.shortWeekdaySymbols[weekday - 1],
                                          count: counts[weekday] ?? 0)
        }
    }

    var exercises: [HealthDashboardExercise] {
        var points: [UUID: [HealthDashboardWeightPoint]] = [:]
        var names: [UUID: String] = [:]
        for workout in workouts {
            // An exercise can occur twice in an imported session. It still contributes
            // a single maximum to that session's progression.
            let grouped = Dictionary(grouping: workout.exercises, by: { $0.exercise.id })
            for (id, entries) in grouped {
                let factor = workout.unit == unit ? 1 : (unit == .kg ? 0.45359237 : 1 / 0.45359237)
                let validSets = entries.flatMap(\.sets).filter {
                    $0.isCompleted && $0.reps > 0 && $0.weight.isFinite && $0.weight >= 0 && ($0.weight * factor).isFinite
                }
                guard let best = validSets.max(by: {
                    if $0.weight != $1.weight { return $0.weight < $1.weight }
                    return $0.reps < $1.reps
                }), let entry = entries.first else { continue }
                names[id] = entry.exercise.name
                points[id, default: []].append(HealthDashboardWeightPoint(workoutID: workout.id,
                    date: workout.startedAt, weight: best.weight * factor, reps: best.reps))
            }
        }
        return points.map { HealthDashboardExercise(id: $0.key, name: names[$0.key] ?? "Exercise", points: $0.value) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    /// Maximum loads within the selected range, choosing the most recent matching set.
    var personalRecords: [HealthDashboardRecord] {
        exercises.compactMap { exercise in
            let maximum = exercise.maximumWeight
            guard let point = exercise.points.last(where: { $0.weight == maximum }) else { return nil }
            return HealthDashboardRecord(exerciseID: exercise.id, name: exercise.name,
                                         weight: point.weight, date: point.date, reps: point.reps)
        }
    }

    func activity(snapshots: [UUID: WorkoutHealthSnapshot]) -> HealthDashboardActivity {
        var metrics: [UUID: (heartRate: Double?, energy: Double?)] = [:]
        for workout in workouts {
            metrics[workout.id] = sessionMetrics(workout: workout, snapshot: snapshots[workout.id])
        }
        let heartRates = workouts.compactMap { metrics[$0.id]?.heartRate }
        let energies = workouts.compactMap { metrics[$0.id]?.energy }
        let groups = Dictionary(grouping: workouts) { $0.templateID?.uuidString ?? "custom" }
        let templates = groups.map { id, sessions in
            let rates = sessions.compactMap { metrics[$0.id]?.heartRate }
            let energy = sessions.compactMap { metrics[$0.id]?.energy }
            return HealthDashboardTemplateActivity(id: id, templateID: sessions.first?.templateID,
                name: sessions.last?.templateID == nil ? "Other workouts" : (sessions.last?.name ?? "Workout"),
                workoutCount: sessions.count,
                totalDuration: sessions.reduce(0) { $0 + ($1.finishedAt?.timeIntervalSince($1.startedAt) ?? 0) },
                averageHeartRate: Self.average(rates), activeEnergy: energy.isEmpty ? nil : energy.reduce(0, +),
                heartRateWorkoutCount: rates.count, energyWorkoutCount: energy.count)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return HealthDashboardActivity(workoutCount: workoutCount, totalDuration: totalDuration, longestDuration: longestDuration,
            averageHeartRate: Self.average(heartRates), activeEnergy: energies.isEmpty ? nil : energies.reduce(0, +),
            heartRateWorkoutCount: heartRates.count, energyWorkoutCount: energies.count, templates: templates)
    }

    private func sessionMetrics(workout: WorkoutSession, snapshot: WorkoutHealthSnapshot?) -> (heartRate: Double?, energy: Double?) {
        guard let snapshot, let scoped = try? snapshot.scoped(to: workout, through: now) else { return (nil, nil) }
        let heartRates = scoped.metrics.filter { $0.metric == .heartRate }.flatMap(\.samples).map(\.value)
        let energies = scoped.metrics.filter { $0.metric == .activeEnergy }.flatMap(\.samples).map(\.value)
        let energy = energies.isEmpty ? nil : energies.reduce(0, +)
        return (Self.average(heartRates), energy.flatMap { $0.isFinite ? $0 : nil })
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { $0 + $1 / Double(values.count) }
    }
}

extension HealthDashboardActivity {
    init(workouts: [WorkoutSession], snapshots: [UUID: WorkoutHealthSnapshot], now: Date = Date()) {
        self = HealthDashboardAnalytics(workouts: workouts, unit: .lb, range: .all, now: now)
            .activity(snapshots: snapshots)
    }
}
