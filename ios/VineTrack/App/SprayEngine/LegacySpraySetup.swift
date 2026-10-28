import Foundation

/// Lossless By Area setup carried by the existing notes contract, not a new start or coverage authority.
nonisolated enum LegacySpraySetup {
    static let marker = "\n[VineTrack sprayer setup v1]\n"
    static let end = "\n[/VineTrack sprayer setup]"
    static let fullTankMessage = "Full-tank planning cannot currently start a spray. Choose By Area to continue."
    static let workMessage = "Proposed passes cannot currently start a spray. Deselect them in Select Work Area to continue; your blocks, equipment and mix stay unchanged."

    static func blocker(intent: SprayPlanningIntent?, resolution: SprayPlanningResolution?, cleared: Bool = false) -> String? {
        guard intent != nil || resolution != nil || cleared else { return nil }
        guard !cleared, let intent else { return "Planning evidence is incomplete. Recalculate this draft before starting." }
        guard intent.method == .byArea else { return fullTankMessage }
        guard let resolution else { return "Choose a pass configuration and complete the carrier settings in this draft before starting." }
        return intent.frozenResolutionBlocker(resolution)
    }

    static func canCarry(_ fields: SprayPlanningWireFields, cleared: Bool = false) -> Bool {
        fields.intent != nil && blocker(intent: fields.intent, resolution: fields.resolution(), cleared: cleared) == nil
    }

    static func notes(_ notes: String, fields: SprayPlanningWireFields) throws -> String {
        guard canCarry(fields) else { return notes }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = String(decoding: try encoder.encode(fields), as: UTF8.self)
        let suffix = marker + payload + end
        if self.fields(in: notes) == fields { return notes }
        // Existing user notes are never deleted, including a prior setup annotation.
        return notes + suffix
    }

    static func fields(in notes: String) -> SprayPlanningWireFields? {
        guard let start = notes.range(of: marker, options: .backwards), notes.hasSuffix(end) else { return nil }
        let body = notes[start.upperBound..<notes.index(notes.endIndex, offsetBy: -end.count)]
        guard let decoded = try? JSONDecoder().decode(SprayPlanningWireFields.self, from: Data(body.utf8)), canCarry(decoded) else { return nil }
        return decoded
    }
}
