import Foundation
import Testing
@testable import VineTrack

@MainActor
struct CatalogueFrontLabelTests {
    @Test(arguments: ["Belanty", "Greenshield", "Sprayseal", "superseded", "pending_review"])
    func exactImageWinsWithoutFallbackRequests(_ example: String) async throws {
        let exact = CatalogueWire(fields: ["id": .string("exact"), "product_id": .string("product"), "review_status": .string(["superseded", "pending_review"].contains(example) ? example : "approved"), "front_label_image_path": .string("labels/\(example).jpg")])
        var calls: Int = 0
        let path = try await CatalogueFrontLabelResolver.resolve(exactRevision: exact,
            product: { _ in calls += 1; return exact }, revision: { _ in calls += 1; return exact })
        #expect(path == "labels/\(example).jpg")
        #expect(calls == 0)
    }

    @Test(arguments: ["MIRAVIS", "Kocide"])
    func fallbackUsesOnlyImageAndKeepsSavedIdentityAndExactFields(_ name: String) async throws {
        let savedID = UUID(); let linkedID = UUID()
        var saved = SavedChemical(id: savedID, vineyardId: UUID(), name: name)
        saved.chemicalV3RevisionId = linkedID
        let before = saved
        let exact = CatalogueWire(fields: [
            "id": .string(linkedID.uuidString), "product_id": .string("product"), "review_status": .string("superseded"),
            "manufacturer": .string("Original manufacturer"), "activity_group_scheme": .string("frac"), "activity_groups": .array([.string("7")]),
            "manufacturer_label_url": .string("https://example.com/exact-label"),
            "vineyard_uses": .array([.object(["targets": .array([.string("Original target")])])]),
            "default_rate_options": .object(["per_hectare": .array([.object(["value": .number(2), "unit": .string("L")])])])
        ])
        let originalFields = exact.fields
        var requests: [String] = []
        let path = try await CatalogueFrontLabelResolver.resolve(exactRevision: exact, product: { id in
            requests.append("product:\(id)")
            return CatalogueWire(fields: ["id": .string(id), "approved_revision_id": .string("approved")])
        }, revision: { id in
            requests.append("revision:\(id)")
            return CatalogueWire(fields: ["id": .string(id), "product_id": .string("product"), "front_label_image_path": .string("labels/\(name)-current.jpg"), "activity_groups": .array([.string("99")]), "review_status": .string("approved")])
        })
        #expect(path == "labels/\(name)-current.jpg")
        #expect(requests == ["product:product", "revision:approved"])
        #expect(exact.fields == originalFields)
        #expect(exact.groupText == "FRAC 7")
        #expect(exact.targets == ["Original target"])
        #expect(exact.rateRows("per_hectare").first?.number("value") == 2)
        #expect(exact.text("review_status") == "superseded")
        #expect(exact.text("manufacturer") == "Original manufacturer")
        #expect(exact.text("manufacturer_label_url") == "https://example.com/exact-label")
        #expect(saved.id == savedID && saved.chemicalV3RevisionId == linkedID)
        #expect(saved == before)
    }

    @Test(arguments: ["", " \n "])
    func neitherRevisionHasImageKeepsPlaceholder(_ blank: String) async throws {
        let exact = CatalogueWire(fields: ["id": .string("exact"), "product_id": .string("product"), "front_label_image_path": .string(blank)])
        let path = try await CatalogueFrontLabelResolver.resolve(exactRevision: exact,
            product: { id in CatalogueWire(fields: ["id": .string(id), "approved_revision_id": .string("approved")]) },
            revision: { id in CatalogueWire(fields: ["id": .string(id), "product_id": .string("product"), "front_label_image_path": .string(blank)]) })
        #expect(path == nil)
    }

    @Test func missingProductOrApprovedPointerDoesNotFetchOtherRevisions() async throws {
        var revisionCalls: Int = 0
        let missingProduct = CatalogueWire(fields: ["id": .string("exact")])
        let noProduct = try await CatalogueFrontLabelResolver.resolve(exactRevision: missingProduct,
            product: { _ in Issue.record("No product lookup expected"); return missingProduct },
            revision: { _ in revisionCalls += 1; return missingProduct })
        #expect(noProduct == nil)
        let exact = CatalogueWire(fields: ["id": .string("exact"), "product_id": .string("product")])
        for pointer in [nil, "exact"] as [String?] {
            let path = try await CatalogueFrontLabelResolver.resolve(exactRevision: exact,
                product: { id in CatalogueWire(fields: ["id": .string(id), "approved_revision_id": pointer.map { .string($0) } ?? .null]) },
                revision: { _ in revisionCalls += 1; return exact })
            #expect(path == nil)
        }
        #expect(revisionCalls == 0)
    }

    @Test func anotherProductsImageIsNeverUsed() async throws {
        let exact = CatalogueWire(fields: ["id": .string("exact"), "product_id": .string("product")])
        let path = try await CatalogueFrontLabelResolver.resolve(exactRevision: exact,
            product: { id in CatalogueWire(fields: ["id": .string(id), "approved_revision_id": .string("approved")]) },
            revision: { id in CatalogueWire(fields: ["id": .string(id), "product_id": .string("other-product"), "front_label_image_path": .string("labels/wrong.jpg")]) })
        #expect(path == nil)
    }

    @Test func failedFallbackLeavesExactDataAvailable() async {
        let exact = CatalogueWire(fields: ["id": .string("exact"), "product_id": .string("product"), "activity_group_scheme": .string("frac"), "activity_groups": .array([.string("7")])])
        let path = try? await CatalogueFrontLabelResolver.resolve(exactRevision: exact,
            product: { _ in throw URLError(.notConnectedToInternet) }, revision: { _ in Issue.record("No revision expected after failure"); return exact })
        #expect(path == nil)
        #expect(exact.groupText == "FRAC 7")
    }
}
