import Foundation

/// Legacy decoders intentionally generate some missing nested identities.
/// Memoization must not freeze those identities or repair the original bytes.
nonisolated enum PersistenceDecodeEligibility {
    static func permits(_ dataset: PersistenceDataset, bytes: Data) -> Bool {
        if dataset == .pins { return true }
        guard dataset == .chemicals || dataset == .blocks,
              let objects = (try? JSONSerialization.jsonObject(with: bytes)) as? [[String: Any]] else { return false }
        if dataset == .chemicals {
            return objects.allSatisfy { chemical in
                guard let rates = optionalArray(chemical["rates"]) else { return false }
                return rates.allSatisfy { validUUID($0["id"]) }
            }
        }
        return objects.allSatisfy { block in
            guard let polygon = block["polygonPoints"] as? [[String: Any]],
                  polygon.allSatisfy({ validUUID($0["id"]) }),
                  let rows = block["rows"] as? [[String: Any]],
                  rows.allSatisfy({ row in
                      guard let start = row["startPoint"] as? [String: Any],
                            let end = row["endPoint"] as? [String: Any] else { return false }
                      return validUUID(start["id"]) && validUUID(end["id"])
                  }),
                  let varieties = optionalArray(block["varietyAllocations"]) else { return false }
            return varieties.allSatisfy { allocation in
                validUUID(allocation["id"]) && (validUUID(allocation["varietyId"])
                    || validUUID(allocation["variety_id"]) || validUUID(allocation["variety"]))
            }
        }
    }

    private static func optionalArray(_ value: Any?) -> [[String: Any]]? {
        if value == nil || value is NSNull { return [] }
        return value as? [[String: Any]]
    }

    private static func validUUID(_ value: Any?) -> Bool {
        guard let string = value as? String else { return false }
        return UUID(uuidString: string) != nil
    }
}
