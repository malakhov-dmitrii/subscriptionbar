import Foundation

public enum RotationDecision: Equatable, Sendable {
    case stay, unavailable(String), switchTo(UUID)
}

public enum RotationPolicy {
    public static func decide(provider: Provider, settings: Settings, readings: [UUID: UsageSnapshot],
                              failures: Set<UUID> = [], now: Date = Date()) -> RotationDecision {
        guard settings.autoSwitch, settings.automationPausedReason == nil,
              settings.enabledProviders.contains(provider),
              let activeID = settings.active[provider],
              let current = settings.accounts.first(where: { $0.id == activeID && $0.provider == provider }),
              current.enabled else { return .stay }
        if let last = settings.lastSwitch[provider], now.timeIntervalSince(last) < 120 { return .stay }
        guard !failures.contains(activeID), let reading = readings[activeID], reading.isFresh(at: now) else { return .stay }
        guard exhausted(reading, account: current, threshold: settings.switchAt) else { return .stay }
        // API-key providers are monitored. Switching an arbitrary external client's
        // environment or hard-coded key cannot be claimed from changing our vault.
        guard current.canSwitch else {
            return .unavailable("Low balance or quota. This provider's client credentials need to be changed in the client.")
        }
        let pool = settings.accounts.filter { $0.provider == provider && $0.enabled && $0.canSwitch }
        guard let index = pool.firstIndex(where: { $0.id == activeID }) else { return .stay }
        let ordered = Array(pool.dropFirst(index + 1)) + Array(pool.prefix(index))
        for target in ordered {
            guard !failures.contains(target.id), let snapshot = readings[target.id], snapshot.isFresh(at: now),
                  !exhausted(snapshot, account: target, threshold: settings.switchAt) else { continue }
            if provider == .claude, reading.windows.contains(where: { $0.name == "Fable · 7 days" && $0.remaining <= 1 }),
               !snapshot.windows.contains(where: { $0.name == "Fable · 7 days" }) { continue }
            return .switchTo(target.id)
        }
        return .unavailable("Limit reached. No other account has a fresh reading with available quota.")
    }

    public static func exhausted(_ reading: UsageSnapshot, account: Account, threshold: Double = 1) -> Bool {
        if account.provider.usesBalance {
            // Never sum different currencies, or treat one empty currency wallet as
            // exhausting a second funded wallet.
            return !reading.balances.isEmpty && reading.balances.allSatisfy { $0.available <= account.balanceThreshold }
        }
        return reading.remainingPercent.map { $0 <= threshold } ?? false
    }
}
