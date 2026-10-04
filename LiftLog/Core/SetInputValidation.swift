import Foundation

/// Parses the text entered in a set row while allowing incomplete input to stay local.
enum SetInputValidation {
    static func weight(from text: String) -> Double? {
        guard !text.isEmpty,
              let value = Double(text.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func reps(from text: String) -> Int? {
        guard let value = Int(text), value > 0 else { return nil }
        return value
    }
}
