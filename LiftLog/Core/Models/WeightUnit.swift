import Foundation

enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case lb, kg
    var id: String { rawValue }
}
