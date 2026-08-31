package com.rork.vinetrack.data.chemical

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The PERSISTED shape of `saved_chemicals.default_rates` (sql/214).
 *
 * This is the storage mirror of the Deno `SavedChemicalDefaultRates` contract
 * in `supabase/functions/chemical-info-lookup/default_rates.ts`. It is
 * deliberately separate from [ChemicalDefaultRateSelection], which is the
 * in-flight UI state: one is a decision being made, the other is the decision
 * that was made. Merging them would let an unconfirmed recommendation reach
 * the database.
 *
 * # What this records, and what it must never become
 *
 * `registered_uses` is label evidence and stays untouched forever. This column
 * records only WHICH authoritative rate the operator confirmed, never a new
 * rate. If it is absent, wrong or unreadable, every calculation still has
 * everything it needs from `registered_uses`, so nothing here confers
 * authority.
 *
 * The amount is a SNAPSHOT of the label's own amount in the LABEL's own unit —
 * not the pack unit, not the inventory unit, never a converted convenience
 * figure. A label reading "3 L/100 L" persists as `value = 3, unit = "L"` even
 * for a product bought in millilitres.
 *
 * # Null is "not recorded", never "no rates exist"
 *
 * A null column means no default has been recorded. A null basis slot means
 * none is recorded FOR THAT BASIS. Neither says anything about what the label
 * offers. Nothing is ever backfilled from `rate_per_ha` or `rates[]`: those are
 * legacy operator numbers with no link back to a registered direction, so
 * deriving a default from them would invent a provenance the data cannot
 * support.
 */
@Serializable
data class StoredChemicalDefaultRates(
    /**
     * ALWAYS encoded, never omitted.
     *
     * kotlinx drops any property equal to its default, and the server rejects a
     * stored value whose version it cannot read (`version_unsupported`) — so a
     * silently omitted `1` would make every Android-written default unreadable
     * on the server and on iOS while looking perfectly correct on device.
     */
    @OptIn(ExperimentalSerializationApi::class)
    @EncodeDefault(EncodeDefault.Mode.ALWAYS)
    val version: Int = DEFAULT_RATES_VERSION,
    @SerialName("per_hectare") val perHectare: StoredChemicalDefaultRate? = null,
    @SerialName("per_100_litres") val per100Litres: StoredChemicalDefaultRate? = null,
) {
    /** The slot for a basis, or null when nothing is recorded on it. */
    fun slot(basis: ChemicalDefaultRateBasis): StoredChemicalDefaultRate? = when (basis) {
        ChemicalDefaultRateBasis.PER_HECTARE -> perHectare
        ChemicalDefaultRateBasis.PER_100_LITRES -> per100Litres
    }

    /** Replace one basis slot, leaving the other exactly as it was. */
    fun withSlot(
        basis: ChemicalDefaultRateBasis,
        slot: StoredChemicalDefaultRate?,
    ): StoredChemicalDefaultRates = when (basis) {
        ChemicalDefaultRateBasis.PER_HECTARE -> copy(perHectare = slot)
        ChemicalDefaultRateBasis.PER_100_LITRES -> copy(per100Litres = slot)
    }

    /** True when neither basis records a choice — the column may then stay null. */
    val isEmpty: Boolean get() = perHectare == null && per100Litres == null

    companion object {
        const val DEFAULT_RATES_VERSION: Int = 1
    }
}

/**
 * One recorded operational default.
 *
 * [rateIds] cites every authoritative registered rate that supports this
 * amount. It is an ARRAY, always: a printed label can state the same amount
 * against several distinct directions (VICOL APVMA 33182 states 3 L/100 L for
 * both European Red Mites and Grapevine Scale), and collapsing them to one id
 * would discard a direction the operator is entitled to rely on.
 */
@Serializable
data class StoredChemicalDefaultRate(
    /** Deterministic identity of the grouped choice. See [ChemicalDefaultRateIdentity]. */
    @SerialName("option_key") val optionKey: String,
    /** Gate D1 `rate_v1_` identities of printed DIRECTIONS. Never UUIDs. At least one. */
    @SerialName("rate_ids") val rateIds: List<String>,
    /** Must equal the slot this selection is stored under. */
    val basis: String,
    /** The label rate's own unit ("L", "mL", "kg", "g"). */
    val unit: String,
    /** Single-value amount, or null when the label states a range. */
    val value: Double? = null,
    /** Lower bound of a true range, else null. */
    @SerialName("min_value") val minValue: Double? = null,
    /** Upper bound of a true range, else null. */
    @SerialName("max_value") val maxValue: Double? = null,
    /**
     * Provenance, never part of identity. `operator` means a human confirmed
     * it. There is deliberately no `inferred`: nothing reconstructs a
     * historical choice, so no value may imply that it did.
     *
     * ALWAYS encoded for the same reason as `version`: the server validates
     * this against a closed vocabulary, and an omitted value would read as
     * "provenance unknown" for a choice a human actually made.
     */
    @OptIn(ExperimentalSerializationApi::class)
    @EncodeDefault(EncodeDefault.Mode.ALWAYS)
    val source: String = SOURCE_OPERATOR,
    /** Provenance. Optional; never part of identity. */
    @SerialName("selected_at") val selectedAt: String? = null,
    /**
     * The label revision the amount was read from. Provenance for "the label
     * has moved on" detection — it must never influence [optionKey], or a
     * reissued label restating the same direction would orphan the default.
     */
    @SerialName("label_version") val labelVersion: String? = null,
) {
    companion object {
        const val SOURCE_OPERATOR: String = "operator"
        const val SOURCE_RECOMMENDED: String = "recommended"
    }
}

/**
 * Helpers for READING canonical default-rate identities.
 *
 * This object used to MINT them, mirroring the server's hashing byte for byte.
 * It no longer can, and deliberately so — see the note where the minting
 * functions were removed. `option_key` and `rate_ids` are issued by the server
 * and carried verbatim by [ChemicalServerDefaultRateOption]; what remains here
 * is only the vocabulary needed to recognise and compare them.
 */
object ChemicalDefaultRateIdentity {
    const val OPTION_ID_VERSION: String = "default_option_v1"

    /**
     * Canonical rate-id list: trimmed, de-duplicated, sorted.
     *
     * Sorting is what makes the identity order-independent — a client listing
     * the Grapevine Scale direction first must reach the same option as one
     * listing European Red Mites first, because they made the same choice.
     */
    fun canonicalRateIds(ids: List<String?>?): List<String> =
        (ids ?: emptyList())
            .mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }
            .distinct()
            .sorted()

    // ------------------------------------------------------------------
    // REMOVED: mintOptionKey / canonicalInput / normaliseText /
    // normaliseNumber / rateIdsFor
    // ------------------------------------------------------------------
    //
    // Android used to re-group `registered_uses` and mint its own
    // `default_option_v1_` key with a local mirror of the server's hashing.
    // The mirror was faithful, and that was the problem: a deterministic copy
    // is only equal to the original for as long as nobody edits either side,
    // and the failure mode is silent and total. One character of drift and the
    // same confirmed choice carries a different identity here than on the
    // Portal, so cross-client recognition and every staleness check quietly
    // stop working — with no error anywhere.
    //
    // The identity now travels one way only: the server issues `option_key`
    // and `rate_ids`, `ChemicalServerDefaultRateOption` carries them verbatim,
    // and `confirmedDefaultRate` copies them into storage. There is no code
    // path left on this device that can construct one.
}

/**
 * Build the persisted record of a CONFIRMED operational choice.
 *
 * Returns null when the option states no usable number — a verbatim direction
 * with no figure is a faithful record, not a rate a calculation may run on — or
 * when no server-minted `rate_id` stands behind it, because an untraceable
 * default is exactly the invented provenance this contract exists to prevent.
 *
 * The amount is copied from the LABEL, never from the operator's typing:
 * [ChemicalLabelRate.value] / `minValue` / `maxValue` are the registered figures
 * exactly as printed. [confirmedValue] is the operator's exact dose INSIDE a
 * band and is accepted only when the option authorises it, so a stored default
 * can never name a dose the label does not cover.
 *
 * @param grapevineUses the authoritative GRAPEVINE uses this option was built
 *   from. Passing the whole label would let a pome-fruit direction supply a
 *   `rate_id` for a vineyard default.
 * @param source `operator` once a human has confirmed. A recommendation nobody
 *   confirmed must never be persisted.
 */
fun confirmedDefaultRate(
    option: ChemicalDefaultRateOption,
    basis: ChemicalDefaultRateBasis,
    grapevineUses: List<ChemicalRegisteredUse>,
    confirmedValue: Double? = null,
    labelVersion: String? = null,
    selectedAt: String? = null,
    source: String = StoredChemicalDefaultRate.SOURCE_OPERATOR,
): StoredChemicalDefaultRate? {
    val rate = option.rate
    val hasUsableAmount = rate.value != null || (rate.minValue != null && rate.maxValue != null)
    if (!hasUsableAmount) return null

    // The identity comes from the SERVER, or the default is not persisted.
    //
    // An option the device assembled from `registered_uses` for display has no
    // server twin, so it stops here rather than being written with an identity
    // this device invented. That is a real refusal with a visible consequence:
    // the review screen reports no canonical rate and offers the corrective
    // actions. A canonical-looking key for a choice the register never issued
    // would be worse — it would look authoritative on every other client and
    // match nothing.
    val server = option.server ?: return null
    if (!server.isValid) return null
    if (server.decisionBasis != basis) return null

    // Copied verbatim, in the server's own order. Not re-sorted, not
    // de-duplicated, not normalised: `option_key` was minted over these exact
    // bytes, so any tidying here would break the pairing it exists to prove.
    val optionKey = server.optionKey.trim()
    val rateIds = server.rateIds.map { it.trim() }

    // The AMOUNT is a scalar OR a range - never both (shared shape D3).
    //
    // An earlier revision stored the confirmed dose in `value` while ALSO
    // keeping the label's `min_value`/`max_value`, which reads back as an
    // amount that is simultaneously "exactly 600" and "anywhere in 560-700".
    // A consumer has no principled way to choose between them. A dose
    // narrowed from a band therefore persists as a plain scalar with both
    // bounds null: the printed band is not lost, because `registered_uses`
    // still carries it verbatim and stays the sole authority on what the
    // label permits.
    val narrowed = confirmedValue?.takeIf { option.isLabelRange && option.authorises(it) }
    val storedValue = narrowed ?: rate.value
    // A band nobody narrowed produces NO record. There is deliberately no
    // minimum, maximum or midpoint fallback anywhere in this contract.
    if (storedValue == null) return null

    return StoredChemicalDefaultRate(
        optionKey = optionKey,
        rateIds = rateIds,
        basis = basis.raw,
        // The LABEL's unit, as the server stated it — never the pack unit.
        unit = server.unit.trim(),
        value = storedValue,
        minValue = null,
        maxValue = null,
        source = source,
        selectedAt = selectedAt ?: java.time.Instant.now().toString(),
        labelVersion = labelVersion,
    )
}

/**
 * The CONFIRMED operational default for a whole selection, in the shape
 * `saved_chemicals.default_rates` stores.
 *
 * Returns null when nothing has been confirmed on either basis, so the column
 * is omitted from the write and a default recorded elsewhere survives
 * untouched. Clearing a default is a separate, deliberate act — never a side
 * effect of saving an unrelated edit.
 *
 * Only EXPLICIT choices are persisted. [ChemicalDefaultRateSelection.resolvedOption]
 * deliberately falls back to the recommendation so the UI can show one, but a
 * recommendation nobody confirmed is not a decision and must never reach the
 * database.
 */
fun ChemicalDefaultRateSelection.storedDefaultRates(
    grapevineUses: List<ChemicalRegisteredUse>,
    labelVersion: String? = null,
): StoredChemicalDefaultRates? {
    if (grapevineUses.isEmpty()) return null
    var stored = StoredChemicalDefaultRates()
    for (basis in ChemicalDefaultRateBasis.entries) {
        // `confirmedOption` - never `resolvedOption`. The latter falls back to
        // the recommendation so a review screen can show one, and a
        // recommendation nobody confirmed must never reach the database.
        val option = confirmedOption(basis) ?: continue
        stored = stored.withSlot(
            basis,
            confirmedDefaultRate(
                option = option,
                basis = basis,
                grapevineUses = grapevineUses,
                confirmedValue = values[basis],
                labelVersion = labelVersion,
            ),
        )
    }
    return stored.takeIf { !it.isEmpty }
}

/**
 * The empty v1 contract that CLEARS every recorded default.
 *
 * Deliberately not null. Null means "leave whatever is stored alone", and the
 * REST client's `explicitNulls = false` drops a null column from the write
 * entirely - so an operator clearing their last default would silently keep
 * it. An explicit version-1 document with both slots absent is the only way to
 * say "there is no default here now" in a form the server and the other
 * clients both read.
 */
fun clearedDefaultRates(): StoredChemicalDefaultRates = StoredChemicalDefaultRates()

/**
 * Whether a stored default still stands against the label as it reads TODAY.
 *
 * A default is a claim about a registered DIRECTION, not about a number. Every
 * `rate_id` it cites must still be present in the refreshed grapevine
 * directions; if any has gone, the default is stale.
 *
 * Deliberately ALL cited ids rather than any: an option merges several
 * directions stating the same amount, and if one of them has been withdrawn
 * the operator's choice no longer means what it meant when they made it.
 *
 * A default citing nothing at all can never be proven current, so it is stale.
 */
fun StoredChemicalDefaultRate.isSupportedBy(
    grapevineUses: List<ChemicalRegisteredUse>,
): Boolean {
    val live = grapevineUses
        .flatMap { it.rates }
        .mapNotNull { it.rateId?.trim()?.takeIf(String::isNotEmpty) }
        .toSet()
    val cited = ChemicalDefaultRateIdentity.canonicalRateIds(rateIds)
    if (cited.isEmpty()) return false
    return cited.all { it in live }
}

/**
 * Bases whose stored default cites a registered rate that has VANISHED.
 *
 * The refreshed label is the only input, and nothing here picks a replacement:
 * not by value, not by array position, not "the first new rate". Two
 * directions can print the same number while carrying different withholding
 * periods, so a silent repoint would move a compliance fact without telling
 * anybody. The operator confirms again, or clears the slot.
 */
fun StoredChemicalDefaultRates.staleBases(
    grapevineUses: List<ChemicalRegisteredUse>,
): List<ChemicalDefaultRateBasis> = ChemicalDefaultRateBasis.entries.filter { basis ->
    slot(basis)?.let { !it.isSupportedBy(grapevineUses) } == true
}

/**
 * The confirmed operational amount a slot records, or null when it records none.
 *
 * The scalar shape is the ONLY valid confirmed amount (see D3 above): a slot
 * still carrying a legacy range with no scalar is a decision that was never
 * finished, and it must not be read as one.
 */
val StoredChemicalDefaultRate.confirmedAmount: Double?
    get() = value?.takeIf { it.isFinite() && it > 0 }
