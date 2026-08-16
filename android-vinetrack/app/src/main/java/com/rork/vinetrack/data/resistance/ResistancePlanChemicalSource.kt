package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability
import com.rork.vinetrack.data.chemical.viticulturalTargets
import com.rork.vinetrack.data.model.SavedChemical

/**
 * Builds Planner product candidates from the vineyard's Chemical Store.
 *
 * Unlike historical reads, this deliberately DOES use today's Chemical Store: the
 * operator is choosing a product to spray in the future, so the current record is the
 * correct source. The ban on re-reading live chemistry applies to reconstructing what a
 * past application contained, which is a different question.
 *
 * Mirrors `ResistancePlanChemicalSource.swift` on iOS.
 */
object ResistancePlanChemicalSource {

    /**
     * Candidates for planning, from saved chemicals.
     *
     * Products with no structured group are omitted, because a product whose FRAC
     * identity is unknown cannot be offered as an option for a chosen group — doing so
     * would be presenting a guess as a match. They remain visible in the Chemical Store
     * itself, where they can be verified.
     */
    fun candidates(
        chemicals: List<SavedChemical>,
        disease: ResistanceDisease,
        vineyardCountry: String?,
    ): List<ResistancePlanChemicalCandidate> = chemicals.mapNotNull { chemical ->
        val signature = ResistanceGroupSignature.of(chemical.activityGroupCodes)
        if (signature.codes.isEmpty()) return@mapNotNull null
        ResistancePlanChemicalCandidate(
            savedChemicalId = chemical.id,
            productName = chemical.name,
            groups = signature,
            availability = ChemicalIntelligenceAvailability.from(chemical.verificationStatus),
            registeredForDisease = registeredUse(chemical, disease),
            countryCode = vineyardCountry,
        )
    }

    /**
     * Whether structured registered-use evidence covers this disease.
     *
     * Returns null — UNKNOWN — when the product carries no registered-use evidence at
     * all. That is the honest answer and it is not the same as `false`: "the label was
     * never captured" and "the label does not cover this disease" would lead an operator
     * to opposite conclusions.
     *
     * Group membership is never consulted. A Group 7 product is not registered for
     * powdery mildew on grapes by virtue of being Group 7, and inferring efficacy from a
     * resistance classification is exactly the overstatement to avoid.
     */
    fun registeredUse(chemical: SavedChemical, disease: ResistanceDisease): Boolean? {
        val intelligence = chemical.resolvedIntelligence
        if (intelligence.registeredUses.isEmpty()) return null
        val targets = intelligence.registeredUses.viticulturalTargets()
        if (targets.isEmpty()) return null
        return targets.any { ResistanceDisease.fromSprayTargetRaw(it.raw) == disease }
    }
}
