import Foundation

/// Validates the completed guided response before rendering any summary structure.
/// When `expectedVerdicts` is non-empty, every finding must name a known
/// exercise and carry one of the Swift-computed verdicts for that name (a
/// name shared by distinct movements may allow more than one); invented
/// names or out-of-set verdicts reject the whole response instead of rendering.
enum WorkoutSummaryStructuredOutput {
    static func markdown(fromJSON json: String, expectedVerdicts: [String: Set<String>] = [:]) throws -> String {
        let unfinished = AppleFoundationModelsError("The on-device answer did not finish. Ask for a shorter answer or resend the question in smaller parts.")
        let empty = AppleFoundationModelsError("The on-device model returned an empty response. Try again.")
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw unfinished
        }
        func trimmed(_ value: Any?) throws -> String {
            guard let text = value as? String else { throw unfinished }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func requiredText(_ value: Any?) throws -> String {
            let text = try trimmed(value)
            guard !text.isEmpty else { throw empty }
            return text
        }
        func optionalText(_ value: Any?) throws -> String? {
            guard let value, !(value is NSNull) else { return nil }
            let text = try trimmed(value)
            return text.isEmpty ? nil : text
        }
        guard try trimmed(object["completion"]) == "complete" else { throw unfinished }
        let headline = try requiredText(object["headline"])
        guard let findings = object["exerciseFindings"] as? [[String: Any]], (1...12).contains(findings.count),
              let nextSession = object["nextSession"] as? [String], (1...2).contains(nextSession.count) else {
            // Reject out-of-bounds arrays rather than silently dropping advice.
            throw unfinished
        }
        let verdicts = Set(WorkoutSummaryExerciseComparison.Verdict.allCases.map(\.rawValue))
        let bullets = try findings.map { finding in
            let exercise = try requiredText(finding["exercise"])
            let text = try requiredText(finding["finding"])
            let verdict = try trimmed(finding["verdict"])
            guard verdicts.contains(verdict) else { throw unfinished }
            if !expectedVerdicts.isEmpty {
                guard expectedVerdicts[exercise]?.contains(verdict) == true else { throw unfinished }
            }
            return "- **\(exercise):** \(text)"
        }
        let suggestions = try nextSession.enumerated().map { index, item in
            "\(index + 1). \(try requiredText(item))"
        }
        var paragraphs = [headline, bullets.joined(separator: "\n"), "**Next session**\n" + suggestions.joined(separator: "\n")]
        if let health = try optionalText(object["healthNote"]) { paragraphs.append(health) }
        if let limitations = try optionalText(object["limitations"]) { paragraphs.append("Note: " + limitations) }
        return paragraphs.joined(separator: "\n\n")
    }
}
