import Testing
import Foundation
@testable import VineTrack

/// Phase 2F.2 — role-aware restricted-vineyard messaging.
///
/// Every case decodes a REAL `get_my_vineyard_access_matrix()` row shape
/// (sql/157 + sql/158) so the tests also protect the wire contract the copy
/// depends on: `vineyard_access_reason`, `membership_role`,
/// `can_manage_billing` and the new `is_billing_authority`.
struct RestrictedVineyardMessagingTests {

    private static let vineyardId = "3f1a1f2e-0000-4000-8000-00000000000a"

    private func entry(
        role: String,
        reason: String,
        hasAccess: Bool = false,
        billingAuthority: Bool? = nil,
        includeBillingAuthorityKey: Bool = true
    ) -> VineyardAccessEntry {
        var fields: [String] = [
            "\"vineyard_id\": \"\(Self.vineyardId)\"",
            "\"vineyard_name\": \"Stockmans Ridge\"",
            "\"membership_role\": \"\(role)\"",
            "\"membership_status\": \"active\"",
            "\"has_vineyard_access\": \(hasAccess)",
            "\"vineyard_access_reason\": \"\(reason)\"",
            "\"vineyard_access_source\": \"none\"",
            "\"is_billing_owner\": false",
            "\"can_manage_billing\": \(role == "owner")",
            "\"requires_billing_attention\": \(role == "owner")"
        ]
        if includeBillingAuthorityKey {
            let value = billingAuthority ?? (role == "owner")
            fields.append("\"is_billing_authority\": \(value)")
        }
        let json = "{\(fields.joined(separator: ","))}"
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(VineyardAccessEntry.self, from: Data(json.utf8))
    }

    private func message(
        role: String,
        reason: String = RestrictedVineyardMessage.soloFundingReasonCode,
        billingAuthority: Bool? = nil,
        includeBillingAuthorityKey: Bool = true,
        hasAccess: Bool = false,
        isMatrixResolved: Bool = true
    ) -> RestrictedVineyardMessage {
        RestrictedVineyardMessage.make(
            vineyardName: "Stockmans Ridge",
            entry: entry(
                role: role,
                reason: reason,
                hasAccess: hasAccess,
                billingAuthority: billingAuthority,
                includeBillingAuthorityKey: includeBillingAuthorityKey
            ),
            isMatrixResolved: isMatrixResolved
        )
    }

    // MARK: Owner with billing authority

    @Test func ownerSeesSoloToTeamUpgrade() {
        let result = message(role: "owner", billingAuthority: true)
        #expect(result.audience == .billingOwner)
        #expect(result.showsUpgradeToTeam)
        #expect(!result.showsReviewBilling)
        #expect(result.title.contains("Team plan"))
        #expect(result.body.contains("covers your own account only"))
        #expect(result.body.contains("Upgrade to a Team plan"))
    }

    @Test func ownerExpiredPlanKeepsReviewBillingNotUpgrade() {
        let result = message(role: "owner", reason: "no_vineyard_entitlement", billingAuthority: true)
        #expect(result.audience == .billingOwner)
        #expect(!result.showsUpgradeToTeam)
        #expect(result.showsReviewBilling)
        #expect(result.title.contains("has expired"))
    }

    // MARK: Co-Owner without billing authority

    @Test func coOwnerSeesManagedByAnotherOwnerWithoutPurchase() {
        let result = message(role: "owner", billingAuthority: false)
        #expect(result.audience == .coOwner)
        #expect(!result.showsUpgradeToTeam)
        #expect(!result.showsReviewBilling)
        #expect(!result.offersBillingAction)
        #expect(result.body.contains("managed by another Owner"))
    }

    @Test func coOwnerMessageNeverNamesTheBillingOwner() {
        let result = message(role: "owner", billingAuthority: false)
        // No identity, email or plan detail of whoever holds billing.
        #expect(!result.body.lowercased().contains("@"))
        #expect(!result.body.lowercased().contains("subscription id"))
        #expect(result.footnote == nil)
    }

    @Test func coOwnerExpiredPlanAlsoHasNoPurchaseAction() {
        let result = message(role: "owner", reason: "no_vineyard_entitlement", billingAuthority: false)
        #expect(result.audience == .coOwner)
        #expect(!result.offersBillingAction)
    }

    // MARK: Manager / Supervisor / Operator

    @Test func managerSeesOwnerManagedMessageWithoutPurchase() {
        let result = message(role: "manager")
        #expect(result.audience == .teamMember)
        #expect(!result.offersBillingAction)
        #expect(result.body.contains("managed by its Vineyard Owner"))
        #expect(result.body.contains("pending invitations remain available"))
    }

    @Test func supervisorSeesOwnerManagedMessageWithoutPurchase() {
        let result = message(role: "supervisor")
        #expect(result.audience == .teamMember)
        #expect(!result.showsUpgradeToTeam)
        #expect(!result.showsReviewBilling)
    }

    @Test func operatorSeesOwnerManagedMessageWithoutPurchase() {
        let result = message(role: "operator")
        #expect(result.audience == .teamMember)
        #expect(!result.offersBillingAction)
        #expect(result.body.contains("Ask the Vineyard Owner to upgrade"))
    }

    @Test func teamMemberExpiredPlanKeepsOwnerManagedCopy() {
        let result = message(role: "operator", reason: "no_vineyard_entitlement")
        #expect(result.audience == .teamMember)
        #expect(!result.offersBillingAction)
        #expect(result.title.contains("has expired"))
    }

    // MARK: Server-confirmed gate

    @Test func unresolvedMatrixNeverShowsUpgradeState() {
        let result = message(role: "owner", billingAuthority: true, isMatrixResolved: false)
        #expect(result.audience == .unresolved)
        #expect(!result.offersBillingAction)
        #expect(result.title == "Checking your VineTrack access…")
    }

    @Test func missingEntryNeverShowsUpgradeState() {
        let result = RestrictedVineyardMessage.make(
            vineyardName: "Stockmans Ridge",
            entry: nil,
            isMatrixResolved: true
        )
        #expect(result.audience == .unresolved)
        #expect(!result.offersBillingAction)
    }

    @Test func stillAccessibleVineyardNeverShowsUpgradeState() {
        let result = message(role: "owner", billingAuthority: true, hasAccess: true)
        #expect(result.audience == .unresolved)
        #expect(!result.offersBillingAction)
    }

    // MARK: Backend compatibility

    @Test func preSql158BackendKeepsOwnerUpgradeAction() {
        // Older backend omits is_billing_authority — an Owner must not lose
        // the action, and a Manager must still be treated as a team member.
        let owner = message(role: "owner", includeBillingAuthorityKey: false)
        #expect(owner.audience == .billingOwner)
        #expect(owner.showsUpgradeToTeam)

        let manager = message(role: "manager", includeBillingAuthorityKey: false)
        #expect(manager.audience == .teamMember)
        #expect(!manager.offersBillingAction)
    }

    @Test func billingAuthorityFieldDecodesFromMatrixRow() {
        #expect(entry(role: "owner", reason: "x", billingAuthority: false).isBillingAuthority == false)
        #expect(entry(role: "owner", reason: "x", billingAuthority: true).isBillingAuthority == true)
        #expect(entry(role: "owner", reason: "x", includeBillingAuthorityKey: false).isBillingAuthority == nil)
    }
}
