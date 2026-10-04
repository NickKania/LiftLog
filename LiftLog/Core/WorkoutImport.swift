import Foundation

struct WorkoutImportWarning: Identifiable {
    let id = UUID()
    let row: Int
    let message: String
}

struct WorkoutImportExerciseMapping: Identifiable {
    var id: String { sourceName }
    let sourceName: String
    let matchedExercise: Exercise?
}

struct WorkoutImportCandidate: Identifiable {
    let id: String
    let session: WorkoutSession
}

struct WorkoutImportPreview {
    let workouts: [WorkoutImportCandidate]
    let exerciseMappings: [WorkoutImportExerciseMapping]
    let warnings: [WorkoutImportWarning]
    let skippedRestRows: Int

    func sessions(selectedIDs: Set<String>, exerciseOverrides: [String: Exercise] = [:]) -> [WorkoutSession] {
        let mappings = Dictionary(uniqueKeysWithValues: exerciseMappings.map { ($0.sourceName, $0.matchedExercise) })
        return workouts.filter { selectedIDs.contains($0.id) }.map { candidate in
            var session = candidate.session
            for index in session.exercises.indices {
                let sourceName = session.exercises[index].exercise.name
                session.exercises[index].exercise = exerciseOverrides[sourceName]
                    ?? mappings[sourceName].flatMap { $0 }
                    ?? session.exercises[index].exercise
            }
            return session
        }
    }
}

struct WorkoutImportResult {
    let importedCount: Int
    let skippedDuplicateCount: Int
}

/// An adapter boundary: future export formats can produce the same preview and sessions.
enum StrongWorkoutImporter {
    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): return message } }
    }

    static func preview(csv: String, unit: WeightUnit, timeZone: TimeZone, catalog: [Exercise]) throws -> WorkoutImportPreview {
        let rows = try parseCSV(csv)
        guard let header = rows.first else { throw ImportError.invalid("This file is empty.") }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let required = ["Date", "Workout Name", "Duration", "Exercise Name", "Set Order", "Weight", "Reps", "Distance", "Seconds", "RPE"]
        guard Set(names).count == names.count, required.allSatisfy(names.contains) else {
            throw ImportError.invalid("Choose a Strong CSV export with Date, Workout Name, Duration, Exercise Name, Set Order, Weight, Reps, Distance, Seconds and RPE columns.")
        }
        let columns = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        var sessions: [WorkoutSession] = []
        var indexes: [String: Int] = [:]
        var invalidGroups: Set<String> = []
        var groupDurations: [String: TimeInterval] = [:]
        var warnings: [WorkoutImportWarning] = []
        var skippedRestRows = 0
        var sourceNames: [String] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            let line = offset + 2
            guard row.count == names.count else {
                warnings.append(.init(row: line, message: "Skipped row: column count does not match the header.")); continue
            }
            func value(_ key: String) -> String { row[columns[key]!].trimmingCharacters(in: .whitespacesAndNewlines) }
            if value("Set Order").lowercased() == "rest timer" { skippedRestRows += 1; continue }
            let dateText = value("Date"), name = value("Workout Name")
            // Length-prefixed source fields prevent ambiguous keys. Unit, timezone and mapping are deliberately excluded.
            let key = "strong:\(dateText.utf8.count):\(dateText):\(name.utf8.count):\(name)"
            guard let date = formatter.date(from: dateText), formatter.string(from: date) == dateText,
                  !name.isEmpty, let duration = durationSeconds(value("Duration")), date.addingTimeInterval(duration).timeIntervalSince1970.isFinite else {
                invalidGroups.insert(key)
                warnings.append(.init(row: line, message: "Skipped workout: invalid date, workout name or duration.")); continue
            }
            if let observed = groupDurations[key], observed != duration {
                invalidGroups.insert(key)
                warnings.append(.init(row: line, message: "Skipped workout: rows disagree about its duration.")); continue
            }
            groupDurations[key] = duration
            guard let distance = optionalNumber(value("Distance")), let seconds = optionalNumber(value("Seconds")), distance >= 0, seconds >= 0 else {
                warnings.append(.init(row: line, message: "Skipped set: invalid distance or seconds.")); continue
            }
            guard distance == 0, seconds == 0 else {
                warnings.append(.init(row: line, message: "Skipped timed or distance set: this app records weight and reps.")); continue
            }
            let exerciseName = value("Exercise Name")
            guard !exerciseName.isEmpty, let weight = Double(value("Weight")), weight.isFinite, weight >= 0,
                  let repsValue = Double(value("Reps")), repsValue.isFinite, repsValue > 0, repsValue.rounded() == repsValue,
                  let reps = Int(exactly: repsValue), let order = Double(value("Set Order")), order.isFinite, order > 0, order.rounded() == order else {
                warnings.append(.init(row: line, message: "Skipped set: exercise name, weight, reps or set order is invalid.")); continue
            }
            if !value("RPE").isEmpty {
                warnings.append(.init(row: line, message: "RPE is not supported and will not be imported."))
            }
            let index: Int
            if let existing = indexes[key] { index = existing } else {
                index = sessions.count
                indexes[key] = index
                sessions.append(WorkoutSession(name: name, startedAt: date, finishedAt: date.addingTimeInterval(duration), unit: unit, importSourceKey: key))
            }
            if !sourceNames.contains(exerciseName) { sourceNames.append(exerciseName) }
            let set = WorkoutSet(weight: weight, reps: reps, isCompleted: true)
            if let exerciseIndex = sessions[index].exercises.firstIndex(where: { $0.exercise.name == exerciseName }) {
                sessions[index].exercises[exerciseIndex].sets.append(set)
            } else {
                sessions[index].exercises.append(WorkoutExercise(exercise: Exercise(name: exerciseName, category: "Custom"), sets: [set]))
            }
        }
        let candidates = sessions.filter { !invalidGroups.contains($0.importSourceKey!) }.map { WorkoutImportCandidate(id: $0.importSourceKey!, session: $0) }
        let includedNames = Set(candidates.flatMap { $0.session.exercises.map(\.exercise.name) })
        let mappings = sourceNames.filter(includedNames.contains).map { sourceName in
            let matches = catalog.filter { Exercise.normalizedName($0.name) == Exercise.normalizedName(sourceName) }
            return WorkoutImportExerciseMapping(sourceName: sourceName, matchedExercise: matches.count == 1 ? matches[0] : nil)
        }
        return WorkoutImportPreview(workouts: candidates, exerciseMappings: mappings, warnings: warnings, skippedRestRows: skippedRestRows)
    }

    private static func optionalNumber(_ text: String) -> Double? {
        if text.isEmpty { return 0 }
        guard let number = Double(text), number.isFinite else { return nil }
        return number
    }

    private static func durationSeconds(_ text: String) -> TimeInterval? {
        // Strong exports durations such as 55m, 1h 5m and 45s.
        let compact = text.lowercased().filter { !$0.isWhitespace }
        let expression = try! NSRegularExpression(pattern: "([0-9]+)(h|m|s)")
        let range = NSRange(compact.startIndex..., in: compact)
        let matches = expression.matches(in: compact, range: range)
        guard !matches.isEmpty, matches.reduce(0, { $0 + $1.range.length }) == range.length else { return nil }
        var seen: Set<String> = []
        var total: Double = 0
        for match in matches {
            guard let numberRange = Range(match.range(at: 1), in: compact), let unitRange = Range(match.range(at: 2), in: compact),
                  let number = Double(compact[numberRange]), number.isFinite else { return nil }
            let unit = String(compact[unitRange])
            guard seen.insert(unit).inserted else { return nil }
            total += number * (unit == "h" ? 3600 : unit == "m" ? 60 : 1)
        }
        // Bound exported workouts to seven days to prevent corrupt durations and unsafe display conversions.
        return total.isFinite && total > 0 && total <= 7 * 24 * 3600 ? total : nil
    }

    /// CSV scanner accepts escaped quotes, quoted newlines, BOM and CRLF. Malformed quoting is rejected.
    private static func parseCSV(_ input: String) throws -> [[String]] {
        var text = input
        if text.first == "\u{FEFF}" { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let chars = Array(text)
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, index = 0
        func finishField() { row.append(field); field = ""; closed = false }
        func finishRow() { finishField(); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = [] }
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(char) }
            } else if char == "," { finishField() }
            else if char == "\n" { finishRow() }
            else if char == "\"" {
                guard field.isEmpty, !closed else { throw ImportError.invalid("The CSV contains malformed quotation marks.") }
                quoted = true
            } else {
                guard !closed else { throw ImportError.invalid("The CSV contains text after a closing quotation mark.") }
                field.append(char)
            }
            index += 1
        }
        guard !quoted else { throw ImportError.invalid("The CSV contains an unfinished quoted field.") }
        if !field.isEmpty || !row.isEmpty || closed { finishRow() }
        return rows
    }
}
