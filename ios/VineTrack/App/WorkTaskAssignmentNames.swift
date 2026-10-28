import Foundation

/// Presentation only. Never changes task identity, membership or labour authority.
final class WorkTaskAssignmentNames {
    static let shared = WorkTaskAssignmentNames(defaults: .standard)
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    static func humanName(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              !["Assigned vineyard member", "Assigned external resource", "Vineyard member", "Unassigned"].contains(name),
              !name.hasPrefix("Vineyard member ("), !name.hasPrefix("External resource ("),
              name.range(of: "(?i)^(?:user )?[0-9a-f]{8}(?:-[0-9a-f-]+)?$", options: .regularExpression) == nil else { return nil }
        return name
    }
    static func memberName(_ member: BackendVineyardMember) -> String? {
        [member.fullName, member.displayName, member.email].compactMap(humanName).first
    }
    func resolve(account: UUID?, vineyard: UUID?, member: UUID?, external: UUID?, label: String? = nil) -> String {
        guard let id = member ?? external else { return "" }
        let fallback = member != nil ? "Assigned vineyard member" : "Assigned external resource"
        guard let account, let vineyard else { return fallback }
        let kind = member != nil ? "member" : "external"
        let key = "task-assignment-name.v1.\(account).\(vineyard).\(kind).\(id)"
        if let name = Self.humanName(label) { defaults.set(name, forKey: key); return name }
        return Self.humanName(defaults.string(forKey: key)) ?? fallback
    }
}
