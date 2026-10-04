import Foundation
import Testing
@testable import VineTrack

@MainActor struct ChemicalInventoryTraceabilityTests {
    @Test(arguments: BackendRole.allCases)
    func inventoryUsesVineyardPermission(_ role: BackendRole) async throws {
        let allowed = role == .owner || role == .manager
        #expect(role.canChangeSettings == allowed)
        let access = BackendAccessControl()
        access.currentRole = role
        #expect(access.legacyAccessControl.canManageSetup == allowed)
        var wrote = false
        var refreshed = false
        do {
            try await CatalogueInventoryMutation.perform(canManageInventory: access.legacyAccessControl.canManageSetup,
                operation: CatalogueInventoryMutation.purchase, chemicalId: UUID(),
                mutate: { wrote = true }, refresh: { _ in refreshed = true })
            #expect(allowed)
        } catch { #expect(!allowed) }
        #expect(wrote == allowed && refreshed == allowed)
    }
    @Test func noMembershipCannotMutateRegardlessOfAdminStatus() async {
        let access = BackendAccessControl()
        #expect(!access.legacyAccessControl.canManageSetup)
        var wrote = false
        do {
            try await CatalogueInventoryMutation.perform(canManageInventory: false,
                operation: "chemical_inventory_mark_finished", chemicalId: UUID(),
                mutate: { wrote = true }, refresh: { _ in })
            Issue.record("Unknown vineyard permission must be denied")
        } catch { }
        #expect(!wrote)
    }
    @Test func exactSharedRPCKeysTrimTextAndPreserveManufacturerDate() throws {
        let fields = ChemicalInventoryTraceability.fields(batch: " LOT-A ", batchDate: "2025-12-01", serial: " SN-A/007 ")
        #expect(Set(fields.keys) == ["p_batch_number", "p_batch_date", "p_serial_number"])
        #expect(fields["p_batch_number"] == .string("LOT-A"))
        #expect(fields["p_batch_date"] == .string("2025-12-01"))
        #expect(fields["p_serial_number"] == .string("SN-A/007"))
        let encoded = try JSONEncoder().encode(fields)
        #expect(try JSONDecoder().decode([String: SprayReportPayloadV1.JSONValue].self, from: encoded) == fields)
        #expect(ChemicalInventoryTraceability.nullableText(" \n ") == .null)
    }
    @Test func unsetFieldsRemainNullAndLegacyHistoryDisplaysNormally() throws {
        let fields = ChemicalInventoryTraceability.fields(batch: "", batchDate: nil, serial: " ")
        #expect(fields["p_batch_date"] == .null && fields["p_serial_number"] == .null)
        let legacy = try JSONDecoder().decode(CatalogueWire.self, from: Data(#"{"purchase_id":"legacy","quantity":8,"unit":"kg","batch_date":null,"serial_number":null}"#.utf8))
        #expect(ChemicalInventoryTraceability.display(legacy).isEmpty)
        #expect(CatalogueInventoryContainer.historyText(legacy) == "8 kg total")
    }
    @Test func purchaseHistoryKeepsDistinctIdentityAndMetadata() throws {
        let history = try JSONDecoder().decode([CatalogueWire].self, from: Data(#"[{"purchase_id":"one","batch_number":"LOT-A","batch_date":"2025-12-01","serial_number":"SN-A/007"},{"purchase_id":"two","batch_number":"LOT-A","batch_date":"2025-12-01","serial_number":"SN-A/007"}]"#.utf8))
        #expect(history.count == 2 && history[0].id != history[1].id)
        #expect(ChemicalInventoryTraceability.display(history[0]) == ["Batch / Lot number: LOT-A", "Production / Batch date: 2025-12-01", "Serial number (if applicable): SN-A/007"])
        let latest = CatalogueWire(fields: ["latest_batch_date": .string("2025-12-01"), "latest_serial_number": .string("SN-A/007")])
        #expect(ChemicalInventoryTraceability.display(latest, latest: true).count == 2)
    }
    @Test func containerCalculationContractsRemainSeparate() {
        #expect(CatalogueInventoryContainer.preview(count: 2, size: 20, unit: "L") == "2 × 20 L = 40 L total")
        #expect(CatalogueInventoryContainer.openingQuantity(count: "2", size: "20", physical: "12", edited: true) == "12")
        let fields = CatalogueInventoryContainer.fields(count: 2, size: 20, unit: "L")
        #expect(fields["p_container_count"] == .number(2))
        #expect(fields["p_container_size"] == .number(20))
        #expect(fields["p_quantity"] == nil && fields["p_percent_remaining"] == nil)
    }
}
