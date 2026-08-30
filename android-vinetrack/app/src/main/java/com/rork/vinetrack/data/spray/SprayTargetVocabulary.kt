package com.rork.vinetrack.data.spray

/**
 * ONE selected spray target — a built-in VineTrack target or a vineyard's own.
 *
 * A tag carries BOTH halves:
 *
 *  * [identifier] — the stable machine value that goes into the
 *    `spray_jobs.targets` / `spray_records.targets` `text[]` columns
 *    (sql/193). Built-ins use their [SprayTarget.raw]; a custom target uses a
 *    deterministic slug of its wording. sql/193 deliberately put NO value
 *    CHECK on those columns, so custom targets need no migration to store.
 *  * [label] — what the operator actually wrote, verbatim.
 *
 * Mirrors the iOS `SprayTargetTag`.
 */
data class SprayTargetTag(
    /** Stable machine identifier. Never displayed. */
    val identifier: String,
    /** Display wording. Verbatim for a custom target. */
    val label: String,
) {
    constructor(target: SprayTarget) : this(target.raw, target.label)

    /** The typed target this tag IS, when VineTrack has a case for it. */
    val builtIn: SprayTarget?
        get() = SprayTarget.entries.firstOrNull { it.raw == identifier }

    /** True for a vineyard-created target the calculator has no typed case for. */
    val isCustom: Boolean get() = builtIn == null
}

/**
 * The rules for turning target WORDING into stable identifiers and back.
 *
 * Pure, so every rule here — slugging, de-duplication, legacy splitting,
 * display projection — is provable without a store, a network or a view.
 * Mirrors the iOS `SprayTargetVocabulary` exactly.
 */
object SprayTargetVocabulary {

    /**
     * The stable identifier for a piece of target wording, or null when the
     * wording carries no usable characters.
     *
     * Deterministic and case-insensitive: "Eutypa Dieback", "eutypa dieback"
     * and "  EUTYPA   DIEBACK  " all slug to `eutypa_dieback`, so a vineyard
     * cannot end up with three tags that mean one thing.
     */
    fun identifier(wording: String): String? {
        val out = StringBuilder()
        var pendingSeparator = false
        for (character in wording.lowercase()) {
            if (character.isLetterOrDigit()) {
                if (pendingSeparator && out.isNotEmpty()) out.append('_')
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return out.toString().ifEmpty { null }
    }

    /**
     * Build a tag from operator-entered wording.
     *
     * Wording that names a target VineTrack already knows resolves to the
     * BUILT-IN tag rather than creating a near-duplicate custom one. Returns
     * null for wording that is empty or has no letters/digits.
     */
    fun tagFromWording(wording: String): SprayTargetTag? {
        val trimmed = wording.trim()
        if (trimmed.isEmpty()) return null
        val identifier = identifier(trimmed) ?: return null
        val builtIn = SprayTarget.entries.firstOrNull { it.raw == identifier }
            ?: SprayTarget.from(trimmed)
        if (builtIn != null) return SprayTargetTag(builtIn)
        return SprayTargetTag(identifier = identifier, label = trimmed)
    }

    /**
     * The tag for a stored identifier. [labels] is the vineyard's target
     * library (identifier -> wording); when it has no entry the identifier is
     * de-slugged so the operator still reads "Eutypa Dieback" rather than a
     * raw `eutypa_dieback`.
     */
    fun tagForIdentifier(
        identifier: String,
        labels: Map<String, String> = emptyMap(),
    ): SprayTargetTag? {
        val trimmed = identifier.trim()
        if (trimmed.isEmpty()) return null
        SprayTarget.entries.firstOrNull { it.raw == trimmed }?.let { return SprayTargetTag(it) }
        return SprayTargetTag(identifier = trimmed, label = labels[trimmed] ?: deslugged(trimmed))
    }

    /** `eutypa_dieback` -> `Eutypa Dieback`. */
    fun deslugged(identifier: String): String =
        identifier.split('_')
            .filter { it.isNotEmpty() }
            .joinToString(" ") { part -> part.replaceFirstChar { it.uppercaseChar() } }

    /**
     * Split an existing free-text target line into individual wordings,
     * trimmed and de-duplicated case-insensitively.
     *
     * The separator set is deliberately CONSERVATIVE: `/`, `&`, `+` and the
     * word "and" are NOT separators, because "Nutrition / Biostimulant" is a
     * single target's own name and splitting it would invent two targets that
     * do not exist.
     */
    fun wordings(raw: String?): List<String> {
        if (raw == null) return emptyList()
        val separators = charArrayOf(',', ';', '\u00B7', '\u2022', '\n')
        val seen = mutableSetOf<String>()
        val out = mutableListOf<String>()
        for (part in raw.split(*separators)) {
            val trimmed = part.trim()
            if (trimmed.isEmpty()) continue
            val key = identifier(trimmed) ?: continue
            if (seen.add(key)) out.add(trimmed)
        }
        return out
    }

    /**
     * Resolve a Program Step's stored target state into ordered tags.
     *
     * [identifiers] (the structured `targets` values) are the SOURCE OF TRUTH
     * whenever non-empty. [wording] (the legacy free-text target line) has two
     * jobs: it supplies the verbatim WORDING for identifiers that have one,
     * and it is the whole selection for a step written before this feature —
     * so "Eutypa Dieback, Botryosphaeria Dieback" loads as two tags, not as
     * one unparsed sentence and not as nothing.
     */
    fun tags(
        identifiers: List<String>,
        wording: String?,
        labels: Map<String, String> = emptyMap(),
    ): List<SprayTargetTag> {
        val parsedWordings = wordings(wording)
        val wordingByIdentifier = buildMap {
            for (text in parsedWordings) {
                identifier(text)?.let { put(it, text) }
            }
        }

        if (identifiers.isEmpty()) {
            return normalised(parsedWordings.mapNotNull(::tagFromWording))
        }

        val resolved = identifiers.mapNotNull { raw ->
            val key = raw.trim()
            if (key.isEmpty()) return@mapNotNull null
            SprayTarget.entries.firstOrNull { it.raw == key }?.let { return@mapNotNull SprayTargetTag(it) }
            // The step's own wording wins over the library: it is what this
            // step said, and it is the only place a bracket or a slash in a
            // custom name survives the slug.
            wordingByIdentifier[key]?.let { return@mapNotNull SprayTargetTag(identifier = key, label = it) }
            tagForIdentifier(key, labels)
        }
        return normalised(resolved)
    }

    /**
     * De-duplicate by identifier and put the selection in a stable order:
     * built-ins first in [SprayTarget.presentationOrder], then custom targets
     * in the order they were added — so two operators who tapped the same
     * targets in a different sequence write the same array.
     */
    fun normalised(tags: List<SprayTargetTag>): List<SprayTargetTag> {
        val seen = mutableSetOf<String>()
        val unique = tags.filter { seen.add(it.identifier) }
        val builtIns = SprayTarget.presentationOrder.mapNotNull { target ->
            unique.firstOrNull { it.identifier == target.raw }
        }
        val customs = unique.filter { it.isCustom }
        return builtIns + customs
    }

    /** The identifiers to store, in normalised order. */
    fun identifiers(tags: List<SprayTargetTag>): List<String> =
        normalised(tags).map { it.identifier }

    /**
     * The typed targets the calculator understands. Custom tags contribute
     * nothing rather than being forced onto a target they are not.
     */
    fun builtIns(tags: List<SprayTargetTag>): List<SprayTarget> =
        normalised(tags).mapNotNull { it.builtIn }

    /** The custom tags, which travel as wording because there is no typed case. */
    fun customs(tags: List<SprayTargetTag>): List<SprayTargetTag> =
        normalised(tags).filter { it.isCustom }

    /**
     * The display line written back to the legacy free-text `target` column —
     * a COMPATIBILITY PROJECTION, never the source of truth.
     */
    fun displayString(tags: List<SprayTargetTag>): String? {
        val ordered = normalised(tags)
        if (ordered.isEmpty()) return null
        return ordered.joinToString(" \u00B7 ") { it.label }
    }
}
