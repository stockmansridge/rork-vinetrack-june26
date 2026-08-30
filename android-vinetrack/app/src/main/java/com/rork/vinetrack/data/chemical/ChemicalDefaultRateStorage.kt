package com.rork.vinetrack.data.chemical

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale

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
 * Deterministic identity for a grouped operational choice.
 *
 * Pure and platform-independent: the same choice yields the same key on the
 * server, on iOS and here. A UUID would change on every write, making the key
 * useless for recognising that two clients chose the same thing.
 *
 * Byte-for-byte mirror of `canonicalDefaultOptionInput` / `mintDefaultOptionKey`
 * in `default_rates.ts`, including the U+001F field separator and U+001E rate
 * separator. Both are needed: without them two different field splits could
 * hash alike.
 *
 * Contains ONLY what makes the choice the choice — basis, label unit, amount
 * and the supporting direction set. Deliberately absent: `source`,
 * `selected_at`, `label_version`, UI ordering, recommendation state, the pack
 * unit, label URL and any cache key. Every one of those can differ between two
 * clients that made the identical choice.
 */
object ChemicalDefaultRateIdentity {
    const val OPTION_ID_VERSION: String = "default_option_v1"

    private const val UNIT_SEPARATOR = '\u001f'
    private const val RECORD_SEPARATOR = '\u001e'

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

    /** Mirror of the Deno `normaliseIdentityText`. */
    fun normaliseText(value: String?): String =
        Normalizer.normalize(value ?: "", Normalizer.Form.NFKC)
            .lowercase(Locale.ROOT)
            .replace(Regex("[^a-z0-9]+"), " ")
            .trim()

    /**
     * Mirror of the Deno `normaliseIdentityNumber`.
     *
     * Absent is the literal `-`, distinct from any numeric value: "no upper
     * bound" and "an upper bound of zero" must never hash alike.
     */
    fun normaliseNumber(value: Double?): String {
        if (value == null || value.isNaN() || value.isInfinite()) return "-"
        val fixed = String.format(Locale.ROOT, "%.6f", value)
            .trimEnd('0')
            .trimEnd('.')
        return if (fixed == "-0") "0" else fixed
    }

    /** The exact bytes hashed for an option identity. */
    fun canonicalInput(
        basis: String,
        unit: String?,
        value: Double?,
        minValue: Double?,
        maxValue: Double?,
        rateIds: List<String?>?,
    ): String {
        val ids = canonicalRateIds(rateIds).map { normaliseText(it) }.sorted()
        return listOf(
            "v=$OPTION_ID_VERSION",
            "basis=${normaliseText(basis).ifEmpty { "-" }}",
            "unit=${normaliseText(unit).ifEmpty { "-" }}",
            "value=${normaliseNumber(value)}",
            "min=${normaliseNumber(minValue)}",
            "max=${normaliseNumber(maxValue)}",
            "rates=${ids.joinToString(RECORD_SEPARATOR.toString()).ifEmpty { "-" }}",
        ).joinToString(UNIT_SEPARATOR.toString())
    }

    /** Mint the deterministic identity of a grouped operational choice. */
    fun mintOptionKey(
        basis: String,
        unit: String?,
        value: Double?,
        minValue: Double?,
        maxValue: Double?,
        rateIds: List<String?>?,
    ): String {
        val input = canonicalInput(basis, unit, value, minValue, maxValue, rateIds)
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(input.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "${OPTION_ID_VERSION}_${digest.take(32)}"
    }

    /**
     * Every authoritative `rate_id` that supports this option's amount.
     *
     * An option merges rates stating the same amount on the same basis, so
     * several printed directions can stand behind one operator choice. All of
     * them are cited: collapsing to the first would discard a direction the
     * operator is entitled to rely on.
     *
     * Server-minted ids only. A rate the server never identified contributes
     * nothing rather than a device-minted substitute, because a locally
     * invented identity would not match on any other client.
     */
    fun rateIdsFor(
        option: ChemicalDefaultRateOption,
        grapevineUses: List<ChemicalRegisteredUse>,
    ): List<String> = grapevineUses
        .flatMap { it.rates }
        .filter { ChemicalDefaultRate.distinctnessKey(it) == option.id }
        .mapNotNull { it.rateId?.trim()?.takeIf(String::isNotEmpty) }
        .distinct()
        .sorted()
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

    val rateIds = ChemicalDefaultRateIdentity.rateIdsFor(option, grapevineUses)
    if (rateIds.isEmpty()) return null

    val optionKey = ChemicalDefaultRateIdentity.mintOptionKey(
        basis = basis.raw,
        unit = rate.unit,
        value = rate.value,
        minValue = rate.minValue,
        maxValue = rate.maxValue,
        rateIds = rateIds,
    )

    // The operator's exact dose is recorded ALONGSIDE the registered figures,
    // never over them: a band stays a band on the record.
    val storedValue = confirmedValue
        ?.takeIf { option.isLabelRange && option.authorises(it) }
        ?: rate.value

    return StoredChemicalDefaultRate(
        optionKey = optionKey,
        rateIds = rateIds,
        basis = basis.raw,
        unit = rate.unit,
        value = storedValue,
        minValue = rate.minValue,
        maxValue = rate.maxValue,
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
        val selectedId = selectedIds[basis] ?: continue
        val option = plan.group(basis).options.firstOrNull { it.id == selectedId } ?: continue
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
