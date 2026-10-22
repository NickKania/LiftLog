import Foundation

/// Validates completed-record drafts without inventing template or import provenance.
enum WorkoutHistoryEditing {
    static func validated(_ draft: WorkoutSession, replacing original: WorkoutSession? = nil) throws -> WorkoutSession {
        var result = draft
        if let original {
            guard draft.id == original.id, draft.unit == original.unit,
                  draft.templateID == original.templateID,
                  draft.templateVersionID == original.templateVersionID,
                  draft.templateVersionNumber == original.templateVersionNumber,
                  draft.importSourceKey == original.importSourceKey,
                  draft.restSeconds == original.restSeconds else {
                throw ValidationError("The recorded unit and source references cannot be changed by a correction.")
            }
        } else {
            guard draft.templateID == nil, draft.templateVersionID == nil,
                  draft.templateVersionNumber == nil, draft.importSourceKey == nil else {
                throw ValidationError("A manual workout cannot claim a template or import source.")
            }
        }
        guard let finish = draft.finishedAt, draft.restTimer == nil,
              finish.timeIntervalSince(draft.startedAt).isFinite,
              (0...604_800).contains(finish.timeIntervalSince(draft.startedAt)) else {
            throw ValidationError("The finish must be on or after the start, with a duration of at most seven days.")
        }
        result.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.notes = normalizedNotes(draft.notes)
        for index in result.exercises.indices {
            let entry = result.exercises[index]
            let previous = original?.exercises.first { $0.id == entry.id }
            if let previous {
                guard entry.exercise == previous.exercise,
                      entry.templateExerciseID == previous.templateExerciseID,
                      entry.supersetID == previous.supersetID,
                      entry.restSeconds == previous.restSeconds else {
                    throw ValidationError("Keep the recorded movement and source links. Remove the entry and add a new exercise to correct the movement.")
                }
            } else if entry.templateExerciseID != nil || entry.supersetID != nil {
                throw ValidationError("New history exercises cannot claim a prescription or superset.")
            }
            for set in entry.sets {
                let previousSet = previous?.sets.first { $0.id == set.id }
                guard set.isCompleted, set.targetReps == previousSet?.targetReps,
                      set.targetWeight == previousSet?.targetWeight else {
                    throw ValidationError("Record completed work only. Original targets must stay unchanged, and added sets have no targets.")
                }
            }
            result.exercises[index].notes = normalizedNotes(entry.notes)
        }
        SupersetGrouping.normalize(&result.exercises)
        try WorkoutStore.validate(WorkoutSnapshot(templates: [], history: [result], activeWorkout: nil, unit: result.unit))
        return result
    }

    static func normalizedNotes(_ notes: String?) -> String? {
        guard let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    struct ValidationError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
