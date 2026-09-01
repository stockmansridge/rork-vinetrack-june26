import Foundation

/// A saved vineyard purchaser (`public.grape_purchasers`, sql/219): a small
/// reusable winery contact book entry — deliberately NOT a CRM (no tags,
/// history, reminders or documents) and never carries financial data.
///
/// Allocations keep their own SNAPSHOT of these details: selecting a
/// purchaser copies the current values onto the allocation, and later edits
/// to this record never rewrite old allocation snapshots.
nonisolated struct GrapePurchaser: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    /// Winery / purchaser name — the only required field.
    var wineryName: String
    var contactName: String?
    var contactEmail: String?
    var contactPhone: String?
    var contactAddress: String?
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        wineryName: String,
        contactName: String? = nil,
        contactEmail: String? = nil,
        contactPhone: String? = nil,
        contactAddress: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.wineryName = wineryName
        self.contactName = contactName
        self.contactEmail = contactEmail
        self.contactPhone = contactPhone
        self.contactAddress = contactAddress
        self.updatedAt = updatedAt
    }
}
