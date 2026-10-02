import Foundation

/// Resolves only a private media path; the linked revision remains authoritative for all other fields.
@MainActor
enum CatalogueFrontLabelResolver {
    static func resolve(
        exactRevision: CatalogueWire,
        product: (String) async throws -> CatalogueWire,
        revision: (String) async throws -> CatalogueWire
    ) async throws -> String? {
        if let path = imagePath(exactRevision) { return path }
        guard let productID = exactRevision.text("product_id"), !productID.isEmpty else { return nil }
        let catalogueProduct = try await product(productID)
        guard catalogueProduct.id.lowercased() == productID.lowercased(),
              let approvedID = catalogueProduct.text("approved_revision_id"), !approvedID.isEmpty,
              approvedID.lowercased() != exactRevision.id.lowercased() else { return nil }
        let approvedRevision = try await revision(approvedID)
        guard approvedRevision.id.lowercased() == approvedID.lowercased(),
              approvedRevision.text("product_id")?.lowercased() == productID.lowercased() else { return nil }
        return imagePath(approvedRevision)
    }

    private static func imagePath(_ revision: CatalogueWire) -> String? {
        guard let path = revision.text("front_label_image_path"),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return path
    }
}
