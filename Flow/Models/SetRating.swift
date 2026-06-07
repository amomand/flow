import Foundation

enum SetRating: String, Codable, CaseIterable {
    case couldNotComplete = "fail"
    case good = "good"
    case tooEasy = "easy"

    var label: String {
        switch self {
        case .couldNotComplete: return "FAIL"
        case .good: return "GOOD"
        case .tooEasy: return "EASY"
        }
    }

    var emoji: String {
        switch self {
        case .couldNotComplete: return "❌"
        case .good: return "✅"
        case .tooEasy: return "🪶"
        }
    }
}
