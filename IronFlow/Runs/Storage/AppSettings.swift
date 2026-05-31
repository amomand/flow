import Foundation
import SwiftUI

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let startDateKey = "trailflow.startDate"
    private let onboardedKey = "trailflow.hasOnboarded"

    /// Default per the brief: 26 April 2026.
    static let defaultStartDate: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 26
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }()

    var startDate: Date {
        didSet { UserDefaults.standard.set(startDate, forKey: startDateKey) }
    }

    var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: onboardedKey) }
    }

    private init() {
        let d = UserDefaults.standard
        self.startDate = (d.object(forKey: startDateKey) as? Date) ?? Self.defaultStartDate
        self.hasOnboarded = d.bool(forKey: onboardedKey)
    }
}
