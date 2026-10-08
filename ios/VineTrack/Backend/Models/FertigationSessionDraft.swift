import Foundation

/// Same-step edits carry frozen products verbatim, changing only nullable actual quantities.
nonisolated struct FertigationSessionDraft {
    let id: UUID
    var step: FertigationDomain.ProgramStep?
    var products: [FertigationDomain.Object]
    var actuals: [String]
    var notes: String
    let isReadOnly: Bool

    init(application: FertigationDomain.Application? = nil) {
        id = application?.id ?? UUID()
        isReadOnly = application.map { !$0.isEditable } ?? false
        if let raw = application?.raw {
            step = .init(raw: ["id": raw["program_step_id"] ?? .null, "name": raw["program_step_name"] ?? .null, "growth_stage_code": raw["growth_stage_code"] ?? .null])
        }
        products = application?.products ?? []
        actuals = products.map { FertigationDomain.number($0, "actual_quantity").map { String($0) } ?? "" }
        notes = application.flatMap { FertigationDomain.string($0.raw, "notes") } ?? ""
    }
    mutating func select(_ selected: FertigationDomain.ProgramStep, totals: FertigationDomain.Totals) throws {
        guard !isReadOnly else { throw FertigationDomain.Failure.reversed }
        if step?.id == selected.id { return }
        // SQL 266 retains frozen fields for surviving product IDs. New chemicals get new snapshots.
        var remaining = try payloads()
        products = try selected.lines.map { line in
            let chemical = FertigationDomain.uuid(line, "savedChemicalId") ?? FertigationDomain.uuid(line, "chemical_id")
            if let chemical, let index = remaining.firstIndex(where: {
                FertigationDomain.uuid($0, "saved_chemical_id") == chemical
                    && FertigationDomain.number($0, "planned_rate") == FertigationDomain.number(line, "rate")
                    && FertigationDomain.string($0, "rate_basis") == FertigationDomain.string(line, "fertigation_rate_basis")
                    && FertigationDomain.string($0, "rate_unit") == FertigationDomain.string(line, "fertigation_rate_unit")
            }) {
                return remaining.remove(at: index)
            }
            return try FertigationDomain.DraftProduct(line: line).payload(totals: totals, step: selected)
        }
        actuals = products.map { FertigationDomain.number($0, "actual_quantity").map { String($0) } ?? "" }
        step = selected
    }
    func payloads() throws -> [FertigationDomain.Object] {
        guard !isReadOnly else { throw FertigationDomain.Failure.reversed }
        return try products.enumerated().map { index, product in
            var raw = product
            let text = actuals[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = Double(text)
            guard text.isEmpty || value.map({ $0.isFinite && $0 >= 0 }) == true else { throw FertigationDomain.Failure.invalidActual }
            raw["actual_quantity"] = text.isEmpty ? .null : value.map(FertigationDomain.JSON.number)
            return raw
        }
    }
    static func canAttach(vineyardId: UUID, selectedVineyardId: UUID?, status: String, isSystemAdmin: Bool) -> Bool {
        isSystemAdmin && vineyardId == selectedVineyardId && ["completed", "corrected", "imported", "estimated"].contains(status)
    }
    func entry(session: IrrigationSession, ownerId: UUID) throws -> FertigationLinkedOutbox.Entry {
        guard session.deletedAt == nil, !isReadOnly, Self.canAttach(vineyardId: session.vineyardId, selectedVineyardId: session.vineyardId, status: session.status, isSystemAdmin: true), let step, step.id != nil else { throw FertigationDomain.Failure.invalidStep }
        let reference = IrrigationPendingSession(id: session.id, vineyardId: session.vineyardId, irrigationSystemId: session.irrigationSystemId, valveId: session.valveId, valveName: session.valveName ?? "", sessionDate: session.sessionDate, durationMinutes: session.durationMinutes, calculationMethod: session.calculationMethod, flowLitresPerHour: session.flowLitresPerHour, meterStartLitres: session.meterStartLitres, meterFinishLitres: session.meterFinishLitres, totalVolumeLitres: session.totalVolumeLitres, startedAt: nil, finishedAt: nil, notes: session.notes, localTotalVolumeLitres: nil, createdAt: Date())
        return .init(id: id, ownerId: ownerId, irrigation: reference, step: step, products: [], notes: notes, phase: .fertigationPending, acknowledgedTotals: .init(allocations: session.blocks.map { .init(areaM2: $0.servicedAreaM2, vines: $0.servicedVineCount.map(Double.init)) }), acknowledgedProducts: try payloads(), existingSession: true)
    }
}
