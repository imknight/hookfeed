import Foundation

struct BackgroundHealth {
    private var graceUntil = Date.distantPast
    private var failures = 0

    mutating func reset(now: Date) {
        graceUntil = now.addingTimeInterval(8)
        failures = 0
    }

    mutating func record(success: Bool, now: Date) -> Bool {
        if success || now < graceUntil { failures = 0 }
        else { failures += 1 }
        return failures >= 3
    }
}
