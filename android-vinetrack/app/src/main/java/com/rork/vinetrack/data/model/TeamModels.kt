package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * A pending team invitation, decoded from `invitations` joined to
 * `vineyards(name)`. Mirrors the iOS `BackendInvitation`. Used to show who has
 * been invited to a vineyard but has not yet accepted.
 */
@Serializable
data class Invitation(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    val email: String,
    val role: String,
    val status: String = "pending",
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("expires_at") val expiresAt: String? = null,
    @SerialName("vineyards") val vineyard: InvitationVineyard? = null,
    // Flat fields from the `list_my_pending_invitations` RPC (sql/155) — the
    // embedded vineyards(name) join is hidden by RLS for users who are not
    // members yet, which left invitation cards without a vineyard identity.
    @SerialName("vineyard_name") val flatVineyardName: String? = null,
    @SerialName("invited_by_name") val invitedByName: String? = null,
) {
    val vineyardName: String?
        get() = flatVineyardName?.takeIf { it.isNotBlank() } ?: vineyard?.name
}

@Serializable
data class InvitationVineyard(val name: String? = null)

/**
 * Vineyard team roles, mirroring the iOS `BackendRole`. Permission helpers match
 * the server RLS rules so the Android UI gates actions identically.
 */
enum class TeamRole(val raw: String, val displayName: String) {
    Owner("owner", "Owner"),
    Manager("manager", "Manager"),
    Supervisor("supervisor", "Supervisor"),
    Operator("operator", "Operator");

    /** Owners and managers may invite members and change vineyard settings. */
    val canManageTeam: Boolean get() = this == Owner || this == Manager

    /** Owners and managers may see costing data (operator categories/rates). */
    val canViewCosting: Boolean get() = this == Owner || this == Manager

    /**
     * May AGREE a price in the field — today, the piece rate per vine on a job
     * that has not been priced yet — and see the resulting total while entering
     * it. Mirrors the iOS `BackendRole.canEnterPricing`.
     *
     * Deliberately WIDER than [canViewCosting]: supervisors run the crew and
     * settle the rate at the vine, so blocking them would push pricing onto
     * paper. It is deliberately NARROWER than review authority: entering a price
     * is not permission to revisit or change one. Once a job is priced, only
     * [canViewCosting] roles may see or amend that figure, and no aggregate
     * total or report is ever exposed by this flag.
     */
    val canEnterPricing: Boolean get() = this == Owner || this == Manager || this == Supervisor

    /** Short description of what this role can do, shown in Roles & Permissions. */
    val permissionSummary: String
        get() = when (this) {
            Owner -> "Full access"
            Manager -> "Financials & settings"
            Supervisor -> "Edit & delete records, price jobs in the field"
            Operator -> "Field operations only"
        }

    companion object {
        /** Resolve a role string (case-insensitive); defaults to Operator. */
        fun from(raw: String?): TeamRole =
            entries.firstOrNull { it.raw.equals(raw?.trim(), ignoreCase = true) } ?: Operator

        /** Roles assignable via the edit-member flow (owner is set via transfer). */
        val assignable: List<TeamRole> get() = listOf(Manager, Supervisor, Operator)
    }
}
