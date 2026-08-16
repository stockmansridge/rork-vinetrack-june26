package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical
import java.time.Instant

/**
 * The single way a NEW spray application freezes Chemical Intelligence onto a
 * product line.
 *
 * Every path that creates a new application — the Spray Calculator, template
 * instantiation, a duplicate, a CSV import, the manual spray sheet — goes
 * through here. Screens must not resolve the Chemical Store and build snapshots
 * themselves: when three call sites each map intelligence their own way, they
 * drift, and the resistance history ends up meaning three different things
 * depending on which button the operator happened to press.
 *
 * The two rules this object exists to enforce:
 *
 *  * **Current at application time.** Chemistry is read from the Chemical Store
 *    as it stands NOW and frozen. Templates and imports are configuration; they
 *    never carry stale chemistry forward.
 *  * **Honest when unresolved.** A product that cannot be matched to a saved
 *    chemical gets no invented actives, no authoritative groups, and no Verified
 *    status — the absence is preserved so the Resistance Engine can say "cannot
 *    assess" instead of "no concern".
 *
 * Mirrors the iOS `ChemicalSnapshotCapture` decision for decision.
 */
object ChemicalSnapshotCapture {

    /** Deterministic match strategies, in the order they are attempted. */
    enum class MatchKind {
        /** Matched on an explicit saved-chemical id carried by the line. */
        IDENTIFIER,

        /** Matched on a country-scoped registration identity key. */
        REGISTRATION_IDENTITY,

        /**
         * Matched on an exactly-equal (trimmed, case-insensitive) product name
         * that is unique in the library.
         */
        EXACT_NAME,

        /** No safe match. Chemistry stays absent or legacy-only. */
        UNRESOLVED,
    }

    /**
     * How a product line was matched to the Chemical Store, and what was frozen
     * as a result.
     *
     * [snapshot] may legitimately be null — that is an honest "nothing known",
     * never a bug to paper over.
     */
    data class Resolution(
        val snapshot: ChemicalLineSnapshot?,
        val savedChemicalId: String?,
        val match: MatchKind,
    ) {
        val isResolved: Boolean get() = savedChemicalId != null
    }

    /**
     * Find the saved chemical a product line refers to, using only
     * deterministic evidence.
     *
     * There is deliberately no fuzzy/partial name strategy: attaching
     * authoritative chemistry to a product because its name merely resembled a
     * library entry is how a resistance history quietly becomes fiction. An
     * exact name matching two or more entries is ambiguous and left unresolved —
     * picking "the first one" would attach one product's chemistry to another
     * product's spray.
     */
    fun resolve(
        savedChemicalId: String?,
        productName: String?,
        registrationIdentityKey: String? = null,
        library: List<SavedChemical>,
    ): Pair<SavedChemical?, MatchKind> {
        // 1. Explicit identity always wins, including for archived products: a
        //    spray applied from an archived record still happened.
        savedChemicalId?.takeIf { it.isNotBlank() }?.let { id ->
            library.firstOrNull { it.id == id }?.let { return it to MatchKind.IDENTIFIER }
        }

        // 2. Country-scoped registration identity — as strong as an id, and the
        //    only cross-tenant-stable product key that exists.
        registrationIdentityKey?.trim()?.takeIf { it.isNotEmpty() }?.let { key ->
            val matches = library.filter { it.resolvedIntelligence.registration?.identityKey == key }
            if (matches.size == 1) return matches[0] to MatchKind.REGISTRATION_IDENTITY
        }

        // 3. Exact, unique display name.
        val name = productName?.trim().orEmpty()
        if (name.isNotEmpty()) {
            val matches = library.filter { it.name.trim().equals(name, ignoreCase = true) }
            if (matches.size == 1) return matches[0] to MatchKind.EXACT_NAME
        }

        return null to MatchKind.UNRESOLVED
    }

    /**
     * Freeze one saved chemical's CURRENT intelligence.
     *
     * Reads [SavedChemical.resolvedIntelligence], so a product that was never
     * structurally verified still contributes its legacy reading — sourced
     * `LEGACY_RECORD` and statused `NEEDS_MATCH`, which is exactly what iOS
     * freezes for the same product.
     */
    fun capture(
        chemical: SavedChemical,
        capturedAt: String = Instant.now().toString(),
    ): ChemicalLineSnapshot? = ChemicalLineSnapshot.capture(
        intelligence = chemical.resolvedIntelligence,
        legacyChemicalGroup = chemical.chemicalGroup,
        savedChemicalId = chemical.id,
        productName = chemical.name,
        capturedAt = capturedAt,
    )

    /**
     * The canonical entry point for a NEW application line.
     *
     * When the product resolves, today's chemistry is frozen. When it does not,
     * any legacy group text the line itself carried is preserved as legacy-only
     * evidence (unverified, schema 0, no actives), and if there is not even
     * that, the snapshot is null. Either way the line survives with its name and
     * rate intact — losing the application would be a worse outcome than not
     * knowing its chemistry.
     */
    fun captureForNewApplication(
        savedChemicalId: String?,
        productName: String?,
        legacyChemicalGroup: String = "",
        registrationIdentityKey: String? = null,
        library: List<SavedChemical>,
        capturedAt: String = Instant.now().toString(),
    ): Resolution {
        val (chemical, match) = resolve(
            savedChemicalId = savedChemicalId,
            productName = productName,
            registrationIdentityKey = registrationIdentityKey,
            library = library,
        )
        if (chemical != null) {
            return Resolution(
                snapshot = capture(chemical, capturedAt),
                savedChemicalId = chemical.id,
                match = match,
            )
        }
        return Resolution(
            snapshot = ChemicalLineSnapshot.capture(
                intelligence = null,
                legacyChemicalGroup = legacyChemicalGroup,
                savedChemicalId = null,
                productName = productName?.takeIf { it.isNotBlank() },
                capturedAt = capturedAt,
            ),
            savedChemicalId = null,
            match = MatchKind.UNRESOLVED,
        )
    }
}
