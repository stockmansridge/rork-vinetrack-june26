import Foundation

/// Insert-only envelope for a canonical reusable Program Step, never a spray record.
nonisolated struct BackendSprayJobTemplateCreate: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let createdBy: UUID
    let configuration: BackendSprayJobTemplateUpdate

    func encode(to encoder: Encoder) throws {
        var object = try JSONDecoder().decode(FertigationDomain.Object.self, from: JSONEncoder().encode(configuration))
        if configuration.operationType == "Fertigation" {
            for key in Self.sprayOnlyKeys { object.removeValue(forKey: key) }
            if case .array(let lines) = object["chemical_lines"] {
                object["chemical_lines"] = .array(lines.map { line in
                    guard case .object(var value) = line else { return line }
                    for key in ["unit", "water_rate", "rate_basis"] { value.removeValue(forKey: key) }
                    return .object(value)
                })
            }
        }
        object["id"] = .string(id.uuidString)
        object["vineyard_id"] = .string(vineyardId.uuidString)
        object["created_by"] = .string(createdBy.uuidString)
        object["is_template"] = .bool(true)
        object["status"] = .string("draft")
        try object.encode(to: encoder)
    }

    static let sprayOnlyKeys: Set<String> = [
        "targets", "target", "equipment_id", "tractor_id", "ground_application_target",
        "carrier_area_basis", "water_volume", "spray_rate_per_ha", "concentration_factor",
        "canopy_size", "canopy_density", "resistance_plan_id"
    ]

    /// A successful status without the exact canonical row is not a save acknowledgement.
    func validated(_ rows: [BackendSprayJobTemplate]) throws -> BackendSprayJobTemplate {
        guard rows.count == 1, let row = rows.first,
              row.id == id, row.vineyardId == vineyardId, row.isTemplate,
              row.operationType == configuration.operationType else {
            throw SprayProgramStepWriteError.invalid("The server did not confirm this Program Step. Keep the draft and retry.")
        }
        return row
    }
}
