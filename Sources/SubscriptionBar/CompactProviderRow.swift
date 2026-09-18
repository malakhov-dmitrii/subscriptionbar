import SwiftUI
import SubscriptionCore

/// Shared mapping from severity to colour so no two views disagree.
extension UsageLevel {
    var tint: Color {
        switch self {
        case .ok: .accentColor
        case .warning: .orange
        case .critical: .red
        case .stale: .secondary
        }
    }
    var textTint: Color {
        switch self {
        case .ok: .primary
        case .warning: .orange
        case .critical: .red
        case .stale: .secondary
        }
    }
}

struct CompactProviderRow: View {
    let provider: Provider
    @ObservedObject var model: AppModel
    @State private var expanded = false

    private var account: Account? {
        model.settings.accounts.first { $0.id == model.settings.active[provider] }
    }
    private var snapshot: UsageSnapshot? { account.flatMap { model.readings[$0.id] } }
    private var fresh: Bool {
        guard let account, let snapshot else { return false }
        return model.credentialAccess.permitsPolling && model.errors[account.id] == nil && snapshot.isFresh(at: model.now)
    }
    /// Keep the last reading on screen when it goes stale. Blanking the whole
    /// dashboard after 90 seconds hides more than it protects; the age label
    /// carries the uncertainty instead.
    private var windows: [UsageWindow] { snapshot?.windows ?? [] }
    private var level: UsageLevel { model.providerLevels[provider] ?? .stale }
    private var warning: Bool { account != nil && (level == .critical || level == .stale) }
    private var accessibilitySummary: String {
        guard account != nil else { return provider.name + ", " + model.t("Not connected") }
        guard !windows.isEmpty else { return provider.name + ", " + model.t("No data yet") }
        return ([provider.name] + windows.map { window in
            let remaining = label(window) + " " + model.t("%@%% remaining", model.percent(window.remaining))
            guard let reset = window.resetsAt else { return remaining }
            return remaining + ", " + model.t("resets %@", ResetCountdown.text(until: reset, now: model.now, language: model.language))
        } + (fresh ? [] : [model.t("Last known data · currently unverified")])).joined(separator: ", ")
    }
    private func label(_ window: UsageWindow) -> String {
        switch window.name {
        case "5 hours": return model.t("5h")
        case "7 days", "Weekly": return model.t("wk")
        case "Monthly": return model.t("mo")
        case "Fable · 7 days": return "Fable"
        case "Primary": return model.t("Primary")
        case "Credits": return model.t("Credits")
        default: return model.message(window.name)
        }
    }
    private func metric(_ window: UsageWindow) -> some View {
        let windowLevel: UsageLevel = fresh ? model.settings.level(window.remaining, stale: false) : .stale
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(label(window)).font(.caption2).foregroundStyle(.secondary)
                Text(model.percent(window.remaining) + "%")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(windowLevel.textTint)
            }
            ProgressView(value: max(0, min(window.remaining, 100)), total: 100)
                .tint(windowLevel.tint)
                .frame(height: 3)
            if let reset = window.resetsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label(ResetCountdown.text(until: reset, now: context.date, language: model.language, compact: true),
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.monospacedDigit()
    }
    private var columns: Int { min(max(windows.count, 1), 3) }
    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(provider.name).font(.callout.weight(.semibold))
                        if warning {
                            Image(systemName: level == .stale ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill")
                                .foregroundStyle(level.tint).font(.caption)
                        }
                        Spacer(minLength: 4)
                        if windows.isEmpty {
                            Text(account == nil ? model.t("Not connected") : model.t("No data yet"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !windows.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns),
                                  alignment: .leading, spacing: 6) {
                            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                                metric(window).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        // The header already says the numbers are what is left, so
                        // only the uncertain case needs its own line.
                        if !fresh {
                            Text(model.t("remaining · not verified just now"))
                                .font(.caption2).foregroundStyle(level.tint)
                        }
                    }
                }.padding(.vertical, 8).padding(.horizontal, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(provider.name)
                .accessibilityValue(accessibilitySummary + ", " + (expanded ? model.t("Expanded") : model.t("Collapsed")))
                .accessibilityHint(model.t("Show accounts and usage details"))
                .help(model.t("Show accounts and usage details"))
            if expanded { ProviderCard(provider: provider, model: model).padding([.horizontal, .bottom], 6) }
        }
    }
}

struct CompactBalances: View {
    let providers: [Provider]
    @ObservedObject var model: AppModel
    @State private var expanded = false

    private func level(_ provider: Provider) -> UsageLevel { model.providerLevels[provider] ?? .stale }

    private func amount(_ provider: Provider) -> String {
        guard let id = model.settings.active[provider], let reading = model.readings[id],
              !reading.balances.isEmpty else { return "—" }
        return reading.balances.map { $0.available.formatted(.currency(code: $0.currency).locale(model.locale)) }.joined(separator: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.t("Balances")).font(.callout.weight(.semibold))
                        if providers.contains(where: { level($0) != .ok }) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        }
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        ForEach(providers) { provider in
                            Text(provider.name + " " + amount(provider)).font(.caption).monospacedDigit()
                                .foregroundStyle(level(provider).textTint)
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(model.t("Balances"))
                .accessibilityValue(providers.map { $0.name + " " + amount($0) }.joined(separator: ", ")
                                    + ", " + (expanded ? model.t("Expanded") : model.t("Collapsed")))
            if expanded {
                ForEach(providers) { provider in ProviderCard(provider: provider, model: model).padding([.horizontal, .bottom], 6) }
            }
        }
    }
}
