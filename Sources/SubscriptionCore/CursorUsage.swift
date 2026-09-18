import Foundation

public enum CursorUsage {
    public static func parse(data: Data, source: String, now: Date) throws -> UsageSnapshot {
        let root = try JSONValue.parse(data)
        guard let individual = root["individualUsage"], individual.object != nil else { throw AppFailure.invalidUsage }
        let end: Date?
        if let raw = root["billingCycleEnd"], raw != .null {
            guard let value = raw.string else { throw AppFailure.invalidUsage }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: value)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? formatter.date(from: value) else { throw AppFailure.invalidUsage }
            end = date
        } else { end = nil }
        var windows: [UsageWindow] = []
        for (field, label) in [("plan", "Plan"), ("overall", "Spending limit"), ("onDemand", "On-demand")] {
            guard let entry = individual[field], entry != .null else { continue }
            guard entry.object != nil else { throw AppFailure.invalidUsage }
            if entry["enabled"]?.bool == false { continue }
            let used: Double
            if field == "plan", let percent = entry["totalPercentUsed"], percent != .null {
                guard let number = percent.number else { throw AppFailure.invalidUsage }
                used = number
            } else {
                guard let cap = entry["limit"]?.number, cap.isFinite, cap > 0 else { continue }
                if let raw = entry["used"]?.number {
                    guard raw.isFinite, raw >= 0 else { throw AppFailure.invalidUsage }
                    used = min(100, raw / cap * 100)
                } else if let remaining = entry["remaining"]?.number {
                    guard remaining.isFinite, remaining >= 0, remaining <= cap else { throw AppFailure.invalidUsage }
                    used = (1 - remaining / cap) * 100
                } else { throw AppFailure.invalidUsage }
            }
            windows.append(try UsageWindow(label, usedPercent: used, resetsAt: end))
        }
        guard !windows.isEmpty else { throw AppFailure.message("Cursor did not return a personal usage limit for this plan.") }
        return try UsageSnapshot(windows: windows, source: source, fetchedAt: now)
    }
}
