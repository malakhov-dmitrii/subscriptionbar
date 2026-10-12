import SwiftUI
import SubscriptionCore

/// A draft editor. The caller owns persistence and compare-and-swap checks.
struct CodexProfilesView: View {
    let settings: SubscriptionCore.Settings
    let save: ([CodexClientProfile], UUID?) throws -> Void
    @State private var profiles: [CodexClientProfile]
    @State private var selection: UUID?
    @State private var baseline: [CodexClientProfile]
    @State private var baselineSelection: UUID?
    @State private var error: String?

    init(settings: SubscriptionCore.Settings, save: @escaping ([CodexClientProfile], UUID?) throws -> Void) {
        self.settings = settings
        self.save = save
        let profiles = settings.effectiveCodexProfiles
        let selection = settings.selectedCodexClientID ?? profiles.first?.id
        _profiles = State(initialValue: profiles)
        _selection = State(initialValue: selection)
        _baseline = State(initialValue: profiles)
        _baselineSelection = State(initialValue: selection)
    }

    private var isDirty: Bool { profiles != baseline || selection != baselineSelection }
    private var currentSelection: UUID? { settings.selectedCodexClientID ?? settings.effectiveCodexProfiles.first?.id }

    var body: some View {
        Section(L10n.ui("Codex client profiles")) {
            Text(L10n.ui("Each profile needs its own data folder. Switching affects only the selected profile."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach($profiles) { $profile in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(L10n.ui("Profile name"), text: $profile.name)
                            .accessibilityLabel(L10n.ui("Profile name"))
                        Button(role: .destructive) { remove(profile.id) } label: { Image(systemName: "trash") }
                            .help(L10n.ui("Remove client profile"))
                            .accessibilityLabel(L10n.ui("Remove client profile"))
                    }
                    LabeledContent(L10n.ui("Data folder")) {
                        TextField("~/.codex", text: $profile.home)
                            .accessibilityLabel(L10n.ui("Data folder"))
                    }
                    LabeledContent(L10n.ui("Codex application")) {
                        TextField(profile.id == CodexClientProfile.legacyID ? L10n.ui("Registered Codex app") : "/Applications/Codex.app",
                                  text: Binding(get: { profile.applicationPath ?? "" }, set: { profile.applicationPath = $0.isEmpty ? nil : $0 }))
                            .accessibilityLabel(L10n.ui("Codex application"))
                    }
                }.textFieldStyle(.roundedBorder).padding(.vertical, 4)
            }
            if !profiles.isEmpty {
                Picker(L10n.ui("Switch in"), selection: $selection) {
                    Text(L10n.ui("Select a profile")).tag(UUID?.none)
                    if let selection, !profiles.contains(where: { $0.id == selection }) {
                        Text(L10n.ui("Unavailable profile")).tag(Optional(selection))
                    }
                    ForEach(profiles) { profile in
                        Text(profile.name.isEmpty ? L10n.ui("Unnamed profile") : profile.name).tag(Optional(profile.id))
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.ui("Add client profile")) {
                    profiles.append(CodexClientProfile(name: L10n.ui("New profile"), home: ""))
                }
                Spacer()
                Button(L10n.ui("Cancel")) { reload() }.disabled(!isDirty && error == nil)
                Button(L10n.ui("Save profiles"), action: persist).disabled(!isDirty)
            }
            Text(L10n.ui("Removing a profile does not delete its data or saved accounts."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: settings.effectiveCodexProfiles) { if !isDirty { reload() } }
        .onChange(of: settings.selectedCodexClientID) { if !isDirty { reload() } }
    }

    private func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    private func reload() {
        profiles = settings.effectiveCodexProfiles
        selection = currentSelection
        baseline = profiles
        baselineSelection = selection
        error = nil
    }

    private func persist() {
        do {
            guard settings.effectiveCodexProfiles == baseline, currentSelection == baselineSelection else {
                throw AppFailure.concurrentChange
            }
            let validated = try CodexClientProfile.validate(profiles)
            guard validated.isEmpty || validated.contains(where: { $0.id == selection }) else {
                throw CodexProfileValidationError.invalidSelection
            }
            try save(validated, selection)
            profiles = validated
            baseline = validated
            baselineSelection = selection
            error = nil
        } catch {
            if error is CodexProfileValidationError || error is AppFailure {
                self.error = error.localizedDescription
            } else {
                let failure = error as NSError
                self.error = L10n.ui("Operation failed (%@, code %d).", failure.domain, failure.code)
            }
        }
    }
}

struct CodexProfilePicker: View {
    let settings: SubscriptionCore.Settings
    let select: (UUID) -> Void

    var body: some View {
        if settings.effectiveCodexProfiles.count > 1 {
            Picker(L10n.ui("Switch in"), selection: Binding(
                get: { settings.selectedCodexProfile?.id },
                set: { if let id = $0 { select(id) } })) {
                    if settings.selectedCodexProfile == nil {
                        Text(L10n.ui("Select a profile")).tag(UUID?.none)
                    }
                    ForEach(settings.effectiveCodexProfiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .accessibilityLabel(L10n.ui("Codex client profile"))
                .controlSize(.small).font(.caption)
                .frame(maxWidth: 280, alignment: .leading)
        }
    }
}
