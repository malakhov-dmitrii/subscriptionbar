import Foundation

public enum KimiCodeUsage {
    public static func parse(data: Data, source: String, now: Date) throws -> UsageSnapshot {
        let root = try JSONValue.parse(data)
        guard root.object != nil else { throw AppFailure.invalidUsage }
        var windows: [UsageWindow] = []
        // Newer Code API pools replace the legacy count-based representation.
        if let pools = nonNull(root["usages"]) {
            guard pools.object != nil else { throw AppFailure.invalidUsage }
            for (key, name) in [("limit_5h", "5 hours"), ("limit_7d", "Weekly"), ("limit_month_total", "Monthly")] {
                guard let pool = pools[key] else { continue }
                guard let ratio = pool["used_ratio"]?.number, ratio.isFinite, (0...1).contains(ratio) else {
                    throw AppFailure.invalidUsage
                }
                windows.append(try UsageWindow(name, usedPercent: ratio * 100, resetsAt: reset(pool)))
            }
            return try UsageSnapshot(windows: windows, source: source, fetchedAt: now)
        }
        if let usage = nonNull(root["usage"]) {
            windows.append(try countWindow(usage, name: "Weekly"))
        }
        if let limits = nonNull(root["limits"]) {
            guard let entries = limits.array else { throw AppFailure.invalidUsage }
            for entry in entries {
                let detail = entry["detail"] ?? entry
                let name = try windowName(entry["window"])
                guard !windows.contains(where: { $0.name == name }) else { throw AppFailure.invalidUsage }
                windows.append(try countWindow(detail, name: name))
            }
        }
        return try UsageSnapshot(windows: windows, source: source, fetchedAt: now)
    }

    private static func countWindow(_ value: JSONValue, name: String) throws -> UsageWindow {
        guard let limit = value["limit"]?.number, limit.isFinite, limit > 0 else { throw AppFailure.invalidUsage }
        let used: Double
        if let raw = value["used"] {
            guard let number = raw.number else { throw AppFailure.invalidUsage }
            used = number
        } else if let remaining = value["remaining"]?.number, remaining.isFinite, (0...limit).contains(remaining) {
            used = limit - remaining
        } else { throw AppFailure.invalidUsage }
        guard used.isFinite, (0...limit).contains(used) else { throw AppFailure.invalidUsage }
        if let raw = value["remaining"] {
            guard let remaining = raw.number, remaining.isFinite, (0...limit).contains(remaining),
                  abs(used + remaining - limit) <= max(1, limit) * 1e-9 else { throw AppFailure.invalidUsage }
        }
        return try UsageWindow(name, usedPercent: used / limit * 100, resetsAt: reset(value))
    }

    private static func nonNull(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return value
    }

    private static func windowName(_ window: JSONValue?) throws -> String {
        guard let duration = window?["duration"]?.number, duration.isFinite, duration > 0,
              duration.rounded() == duration, duration <= 525_600,
              let unit = window?["timeUnit"]?.string else { throw AppFailure.invalidUsage }
        let minutes: Double
        switch unit {
        case "TIME_UNIT_MINUTE": minutes = duration
        case "TIME_UNIT_HOUR": minutes = duration * 60
        case "TIME_UNIT_DAY": minutes = duration * 1440
        default: throw AppFailure.invalidUsage
        }
        switch minutes {
        case 300: return "5 hours"
        case 10080: return "Weekly"
        default:
            if minutes.truncatingRemainder(dividingBy: 1440) == 0 { return "\(Int(minutes / 1440)) days" }
            if minutes.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(minutes / 60)) hours" }
            return "\(Int(minutes)) minutes"
        }
    }

    private static func reset(_ value: JSONValue) throws -> Date? {
        for key in ["resetTime", "reset_time", "resetAt", "reset_at"] {
            guard let raw = value[key] else { continue }
            if case .null = raw { continue }
            guard let text = raw.string else { throw AppFailure.invalidUsage }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw AppFailure.invalidUsage }
            return date
        }
        return nil
    }
}
