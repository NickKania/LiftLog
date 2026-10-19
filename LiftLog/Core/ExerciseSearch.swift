import Foundation

/// Search is a projection only: aliases never rename, combine, or register exercises.
struct ExerciseSearchMatch: Equatable, Identifiable {
    enum Kind: Equatable {
        case direct, alias, approximate
    }

    let exercise: Exercise
    let kind: Kind
    let matchedAlias: String?

    var id: UUID { exercise.id }

    var displayReason: String? {
        switch kind {
        case .direct: nil
        case .alias: matchedAlias.map { "Also known as “\($0)”" }
        case .approximate: "Similar spelling"
        }
    }
}

/// Precomputed alongside discovery metadata whenever the available catalog changes.
struct ExerciseSearchDocument {
    struct Text {
        let display: String
        let normalized: String
        let tokens: [Token]

        init(_ value: String) {
            display = value
            normalized = ExerciseSearchEngine.normalize(value)
            tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map { Token(String($0)) }
        }
    }

    struct Token {
        let value: String
        let characters: [Character]

        init(_ value: String) {
            self.value = value
            characters = Array(value)
        }
    }

    let exercise: Exercise
    let name: Text
    let category: Text
    let aliases: [Text]

    init(exercise: Exercise, detail: ExerciseDetail?) {
        self.exercise = exercise
        name = Text(exercise.name)
        category = Text(exercise.category)
        var labels = [exercise.name]
        // Legacy starter labels retain their familiar names; upstream record labels
        // remain discoverable through their existing identity and provenance.
        if let record = detail?.source.sourceRecordID, !record.isEmpty {
            labels.append(record.replacingOccurrences(of: "_", with: " "))
        }
        let replacements = [
            ("overhead press", "OHP"),
            ("romanian deadlift", "RDL"),
            ("dumbbell", "DB"),
            ("barbell", "BB")
        ]
        // Each phrase substitution preserves all other variant words. Applying
        // replacements cumulatively supports combinations such as DB RDL.
        for (phrase, alias) in replacements {
            for label in labels {
                let text = Text(label)
                let phraseTokens = Text(phrase).tokens.map(\.value)
                let words = text.tokens.map(\.value)
                guard let start = words.indices.first(where: {
                    $0 + phraseTokens.count <= words.count &&
                        Array(words[$0..<($0 + phraseTokens.count)]) == phraseTokens
                }) else { continue }
                let before = words[..<start]
                let after = words[(start + phraseTokens.count)...]
                labels.append((Array(before) + [alias] + Array(after)).joined(separator: " "))
            }
        }
        var seen = Set([name.normalized])
        aliases = labels.compactMap { label in
            let text = Text(label)
            guard seen.insert(text.normalized).inserted else { return nil }
            return text
        }
    }
}

enum ExerciseSearchEngine {
    private struct RankedMatch {
        let match: ExerciseSearchMatch
        let rank: Int
        let position: Int
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func matches(_ search: String, documents: [ExerciseSearchDocument]) -> [ExerciseSearchMatch] {
        let query = ExerciseSearchDocument.Text(search)
        guard !query.normalized.isEmpty else {
            return documents.map { ExerciseSearchMatch(exercise: $0.exercise, kind: .direct, matchedAlias: nil) }
        }
        var matches: [RankedMatch] = []
        for (position, document) in documents.enumerated() {
            if document.name.normalized == query.normalized {
                matches.append(ranked(document, kind: .direct, rank: 0, position: position))
            } else if document.name.normalized.contains(query.normalized) || tokensMatch(query, in: document.name) {
                matches.append(ranked(document, kind: .direct, rank: 1, position: position))
            } else if document.category.normalized.contains(query.normalized) || tokensMatch(query, in: document.category) {
                matches.append(ranked(document, kind: .direct, rank: 2, position: position))
            } else if let alias = document.aliases.first(where: { aliasMatches(query, in: $0) }) {
                matches.append(ranked(document, kind: .alias, alias: alias.display, rank: 2, position: position))
            }
        }
        if !matches.isEmpty { return sorted(matches) }

        // Keep arbitrary pasted/custom names cheap and avoid guesses for short
        // fragments. Exact short context words (e.g. "up") can accompany a typo.
        guard query.normalized.count <= 80, !query.tokens.isEmpty, query.tokens.count <= 8,
              query.tokens.contains(where: { $0.characters.count >= 4 }) else { return [] }
        for (position, document) in documents.enumerated() {
            var best: (cost: Int, alias: String?)?
            for (text, alias) in [(document.name, Optional<String>.none)] + document.aliases.map({ ($0, Optional($0.display)) }) {
                guard let cost = approximateCost(query, in: text) else { continue }
                if best == nil || cost < (best?.cost ?? Int.max) { best = (cost, alias) }
            }
            if let best {
                matches.append(ranked(document, kind: .approximate, alias: best.alias,
                                      rank: best.cost, position: position))
            }
        }
        return sorted(matches)
    }

    private static func ranked(_ document: ExerciseSearchDocument, kind: ExerciseSearchMatch.Kind,
                               alias: String? = nil, rank: Int, position: Int) -> RankedMatch {
        RankedMatch(match: ExerciseSearchMatch(exercise: document.exercise, kind: kind, matchedAlias: alias),
                    rank: rank, position: position)
    }

    private static func sorted(_ matches: [RankedMatch]) -> [ExerciseSearchMatch] {
        matches.sorted { $0.rank == $1.rank ? $0.position < $1.position : $0.rank < $1.rank }.map(\.match)
    }

    private static func aliasMatches(_ query: ExerciseSearchDocument.Text, in text: ExerciseSearchDocument.Text) -> Bool {
        query.normalized == text.normalized || tokensMatch(query, in: text, allowShortSubstrings: false)
    }

    private static func tokensMatch(_ query: ExerciseSearchDocument.Text, in text: ExerciseSearchDocument.Text,
                                    allowShortSubstrings: Bool = true) -> Bool {
        guard !query.tokens.isEmpty, query.tokens.count <= text.tokens.count else { return false }
        var remaining = text.tokens.map(\.value)
        for token in query.tokens {
            guard let index = remaining.firstIndex(where: {
                $0 == token.value || ((allowShortSubstrings || token.characters.count >= 4) && $0.contains(token.value))
            }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    private static func approximateCost(_ query: ExerciseSearchDocument.Text, in text: ExerciseSearchDocument.Text) -> Int? {
        guard query.tokens.count <= text.tokens.count else { return nil }
        var remaining = text.tokens
        var cost = 0
        // Consume exact context first, so a nearby word cannot steal its token.
        var unmatched: [ExerciseSearchDocument.Token] = []
        for token in query.tokens {
            if let index = remaining.firstIndex(where: { $0.value == token.value }) {
                remaining.remove(at: index)
            } else {
                unmatched.append(token)
            }
        }
        guard !unmatched.isEmpty else { return nil }
        for token in unmatched {
            guard token.characters.count >= 4 else { return nil }
            let limit = token.characters.count >= 8 ? 2 : 1
            var best: (index: Int, distance: Int)?
            for (index, candidate) in remaining.enumerated() {
                guard let distance = editDistance(token.characters, candidate.characters, limit: limit) else { continue }
                if best == nil || distance < (best?.distance ?? Int.max) { best = (index, distance) }
            }
            guard let best else { return nil }
            cost += best.distance
            guard cost <= 2 else { return nil }
            remaining.remove(at: best.index)
        }
        return cost
    }

    /// Bounded optimal-string-alignment distance, including adjacent transposition.
    private static func editDistance(_ left: [Character], _ right: [Character], limit: Int) -> Int? {
        guard abs(left.count - right.count) <= limit, !left.isEmpty, !right.isEmpty else { return nil }
        var previous = Array(0...right.count)
        var beforePrevious = previous
        for row in 1...left.count {
            var current = Array(repeating: limit + 1, count: right.count + 1)
            current[0] = row
            let lower = max(1, row - limit)
            let upper = min(right.count, row + limit)
            guard lower <= upper else { return nil }
            for column in lower...upper {
                current[column] = min(previous[column] + 1, current[column - 1] + 1,
                                      previous[column - 1] + (left[row - 1] == right[column - 1] ? 0 : 1))
                if row > 1, column > 1, left[row - 1] == right[column - 2], left[row - 2] == right[column - 1] {
                    current[column] = min(current[column], beforePrevious[column - 2] + 1)
                }
            }
            guard (current.min() ?? limit + 1) <= limit else { return nil }
            beforePrevious = previous
            previous = current
        }
        let distance = previous[right.count]
        return distance <= limit ? distance : nil
    }
}
