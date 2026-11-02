import Foundation
import CryptoKit

/// Identity-only containment of an incompatible original WAL, never a migration or receipt.
/// Called only when the strict legacy reader cannot establish the whole journal.
enum LegacyReplayIsolation {
    struct Held {
        let index: Int
        let owner: UUID?
        let vineyard: UUID?
        let trip: UUID?
        let record: UUID?
        let references: Set<UUID>
        var attributable: Bool { owner != nil && vineyard != nil && trip != nil && record != nil }
    }
    struct Inspection {
        let held: [Held]
        let fingerprint: String
        func blocker(trip: UUID?, record: UUID?) -> String? {
            let ids = Set([trip, record].compactMap { $0 })
            if held.contains(where: { !$0.references.isDisjoint(with: ids) }) { return "LEGACY_SAME_TRIP_CONFLICT" }
            if held.contains(where: { !$0.attributable }) { return "LEGACY_IDENTITY_UNRESOLVED" }
            return nil
        }
    }
    nonisolated private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    nonisolated private static func references(_ value: Any) -> Set<UUID> {
        if let object = value as? [String: Any] { return object.values.reduce(into: Set<UUID>()) { $0.formUnion(references($1)) } }
        if let array = value as? [Any] { return array.reduce(into: Set<UUID>()) { $0.formUnion(references($1)) } }
        if let id = uuid(value) { return [id] }
        return []
    }
    nonisolated private static func embedded(_ value: Any?) -> [String: Any]? {
        guard let text = value as? String, let bytes = Data(base64Encoded: text) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
    static func inspect(_ bytes: Data?) -> Inspection {
        let fingerprint = SHA256.hash(data: bytes ?? Data()).map { String(format: "%02x", $0) }.joined()
        guard let bytes else { return Inspection(held: [], fingerprint: fingerprint) }
        guard let rows = (try? JSONSerialization.jsonObject(with: bytes)) as? [Any] else {
            return Inspection(held: [Held(index: -1, owner: nil, vineyard: nil, trip: nil, record: nil, references: [])], fingerprint: fingerprint)
        }
        let held = rows.enumerated().map { index, row -> Held in
            let object = row as? [String: Any]
            let scope = object?["scope"] as? [String: Any]
            let trip = embedded(object?["tripBytes"])
            let record = embedded(object?["recordBytes"])
            let vineyard = uuid(scope?["vineyard"])
            let tripID = uuid(trip?["id"])
            // Missing/contradictory nested identity is global protection, not permission to guess.
            let consistent = vineyard != nil && uuid(trip?["vineyardId"]) == vineyard &&
                uuid(record?["vineyardId"]) == vineyard && uuid(record?["tripId"]) == tripID && tripID != nil
            var refs = references(row)
            if let trip { refs.formUnion(references(trip)) }
            if let record { refs.formUnion(references(record)) }
            // RPC envelopes also carry base64 bodies. Retain their references when inspectable.
            if let rpc = object?["rpc"] as? [String: Any] {
                for key in ["trip", "record"] { if let body = embedded(rpc[key]) { refs.formUnion(references(body)) } }
            }
            return Held(index: index, owner: consistent ? uuid(scope?["actor"]) : nil,
                vineyard: vineyard, trip: tripID, record: uuid(record?["id"]), references: refs)
        }
        return Inspection(held: held, fingerprint: fingerprint)
    }
}
