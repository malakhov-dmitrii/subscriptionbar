import Foundation

public struct CodexClientProfile: Codable, Equatable, Sendable, Identifiable {
    public static let legacyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    public var id: UUID
    public var name: String
    public var home: String
    public var applicationPath: String?

    public init(id: UUID = UUID(), name: String, home: String, applicationPath: String? = nil) {
        self.id = id
        self.name = name
        self.home = home
        self.applicationPath = applicationPath
    }

    /// Validates the complete set before it can become a collection of write targets.
    public static func validate(_ profiles: [Self]) throws -> [Self] {
        var ids = Set<UUID>()
        var homes = Set<String>()
        return try profiles.map { profile in
            guard ids.insert(profile.id).inserted else { throw CodexProfileValidationError.duplicateID }
            var result = profile
            result.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.name.isEmpty else { throw CodexProfileValidationError.missingName }
            result.home = try canonicalPath(profile.home, failure: .invalidHome)
            guard homes.insert(result.home).inserted else { throw CodexProfileValidationError.duplicateHome }
            if let applicationPath = profile.applicationPath {
                let canonical = try canonicalPath(applicationPath, failure: .invalidApplication)
                guard URL(fileURLWithPath: canonical).pathExtension.lowercased() == "app" else {
                    throw CodexProfileValidationError.invalidApplication
                }
                result.applicationPath = canonical
            } else if profile.id != legacyID {
                throw CodexProfileValidationError.invalidApplication
            }
            return result
        }
    }

    public static func selected(in settings: Settings) throws -> Self {
        let profiles = try validate(settings.effectiveCodexProfiles)
        guard let selected = settings.selectedCodexProfile,
              let profile = profiles.first(where: { $0.id == selected.id }) else {
            throw CodexProfileValidationError.invalidSelection
        }
        return profile
    }

    private static func canonicalPath(_ path: String, failure: CodexProfileValidationError) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw failure
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw failure }
        let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        guard canonical != "/" else { throw failure }
        return canonical
    }
}

public enum CodexProfileValidationError: Error, LocalizedError, Equatable, Sendable {
    case missingName, invalidHome, duplicateHome, duplicateID, invalidApplication, invalidSelection

    public var errorDescription: String? {
        let key: String
        switch self {
        case .missingName: key = "Give each Codex profile a name."
        case .invalidHome: key = "Choose an absolute Codex data folder, not the filesystem root."
        case .duplicateHome: key = "Codex profiles must use separate data folders. These folders resolve to the same location."
        case .duplicateID: key = "Codex profile identifiers must be unique."
        case .invalidApplication: key = "Choose an absolute path to a Codex .app for this profile."
        case .invalidSelection: key = "Select a configured Codex profile before switching."
        }
        return L10n.tr(key, table: "UI")
    }
}

extension Settings {
    public var effectiveCodexProfiles: [CodexClientProfile] {
        codexClientProfiles ?? [CodexClientProfile(id: CodexClientProfile.legacyID,
                                                  name: "Codex", home: codexHome)]
    }

    public var selectedCodexProfile: CodexClientProfile? {
        let profiles = effectiveCodexProfiles
        guard let selectedCodexClientID else { return profiles.first }
        return profiles.first { $0.id == selectedCodexClientID }
    }

    /// A source-specific copy for credential reads; never changes saved-account selection.
    public func settings(forCodexProfile profile: CodexClientProfile) -> Settings {
        var copy = self
        copy.codexHome = profile.home
        copy.selectedCodexClientID = profile.id
        return copy
    }
}
