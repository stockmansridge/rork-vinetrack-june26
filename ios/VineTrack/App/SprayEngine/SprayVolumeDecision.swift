import Foundation

/// What the canopy recommends — the CF 1.00 reference volume.
///
/// This is the DILUTE (to-runoff) volume the selected canopy demands. It is a
/// reference, not an instruction: the sprayer in the shed may well be
/// calibrated to something else, and the operator is asked about that
/// separately. Conflating the two is what made the previous screen unable to
/// show a concentration factor that meant anything — there was only ever one
/// volume, so there was nothing to compare it against.
nonisolated struct SprayCanopyRecommendation: Sendable, Hashable {
    let type: CanopyType
    let size: CanopySize
    let density: CanopyDensity
    /// The canopy table's answer, in L/100 m. Always available: the table is a
    /// per-100 m table and needs no row spacing.
    let diluteLitresPer100Metres: Double
    /// Row spacing, from canonical geometry. `nil` when the blocks disagree or
    /// none is set.
    let rowSpacingMetres: Double?

    /// The same recommendation per hectare. `nil` when row spacing is unknown —
    /// never defaulted, because a guessed spacing silently scales the figure
    /// the operator is about to compare their sprayer against.
    var diluteLitresPerHectare: Double? {
        SprayCarrierConversion.litresPerHectare(
            litresPer100Metres: diluteLitresPer100Metres,
            rowSpacingMetres: rowSpacingMetres
        )
    }
}

/// Whether the sprayer will apply the recommended volume, or something else.
///
/// Three states, not a Bool. "Not asked yet" is a real and distinct answer:
/// pre-selecting either option would put a volume into the calculation that
/// nobody chose, which is the same class of defect as the unconfirmed
/// Medium/Low canopy.
nonisolated enum SprayVolumeChoice: String, Sendable, Hashable, Codable, CaseIterable {
    case undecided
    /// Spray at the canopy's dilute volume. CF is 1.00 by construction.
    case useRecommended
    /// Spray at the machine's own calibrated output.
    case useCustomSprayerRate
}

/// The recommended-versus-actual decision, resolved.
///
/// # Why this is one type and not three view properties
///
/// The recommended volume, the actual sprayer output and the concentration
/// factor are one decision with one set of rules:
///
/// ```text
/// recommended = canopy table  →  L/100 m  →  L/ha (through row spacing)
/// actual      = recommended, or the operator's own figure
/// CF          = max(1.00, recommended ÷ actual)
/// ```
///
/// Splitting those across a SwiftUI body is exactly how the two carrier screens
/// ended up disagreeing about the concentration factor. The view reads this
/// type; it does not reproduce it.
nonisolated struct SprayVolumeDecision: Sendable, Hashable {
    let recommendation: SprayCanopyRecommendation?
    let choice: SprayVolumeChoice
    /// The operator's own sprayer output, as typed — ONE number.
    ///
    /// Retained even while `choice` is `.useRecommended`, so switching back and
    /// forth does not destroy a figure they entered.
    let customRate: Double?
    /// The unit `customRate` was entered in.
    ///
    /// Held beside the value rather than as a second field, because 600 L/ha
    /// and 16.8 L/100 m at 2.8 m spacing are the SAME sprayer output. Keeping
    /// an independent number per basis would let the two drift, and the
    /// operator would have no way to tell which one the tank was mixed from.
    let customBasis: SprayCarrierBasis

    // MARK: - Recommended (CF 1.00 reference)

    var recommendedLitresPer100Metres: Double? {
        recommendation?.diluteLitresPer100Metres
    }

    var recommendedLitresPerHectare: Double? {
        recommendation?.diluteLitresPerHectare
    }

    // MARK: - Actual sprayer output

    /// What the machine will actually put out, in L/ha.
    ///
    /// Under `.useRecommended` this TRACKS the recommendation rather than
    /// copying it, so changing the canopy afterwards moves the actual output
    /// with it. Under `.useCustomSprayerRate` the operator's figure stands and
    /// the canopy change moves only the recommendation — and therefore the
    /// concentration factor, which is the entire point of asking.
    var actualLitresPerHectare: Double? {
        switch choice {
        case .undecided:
            return nil
        case .useRecommended:
            return recommendedLitresPerHectare
        case .useCustomSprayerRate:
            guard let rate = positive(customRate) else { return nil }
            switch customBasis {
            case .litresPerHectare:
                return rate
            case .litresPer100Metres:
                return SprayCarrierConversion.litresPerHectare(
                    litresPer100Metres: rate,
                    rowSpacingMetres: recommendation?.rowSpacingMetres
                )
            }
        }
    }

    /// The same actual output expressed per 100 m of row.
    var actualLitresPer100Metres: Double? {
        switch choice {
        case .undecided:
            return nil
        case .useRecommended:
            // Straight from the table, not round-tripped through hectares, so
            // an unknown row spacing still yields a usable row-length figure.
            return recommendedLitresPer100Metres
        case .useCustomSprayerRate:
            guard let rate = positive(customRate) else { return nil }
            switch customBasis {
            case .litresPer100Metres:
                return rate
            case .litresPerHectare:
                return SprayCarrierConversion.litresPer100Metres(
                    litresPerHectare: rate,
                    rowSpacingMetres: recommendation?.rowSpacingMetres
                )
            }
        }
    }

    // MARK: - Concentration factor

    /// `max(1.00, recommended ÷ actual)`, from the one shared definition.
    ///
    /// Computed per hectare when both figures are available, falling back to
    /// the per-100 m pair when row spacing is unknown. Both give the same
    /// answer — the spacing cancels — so the fallback is a way of still
    /// answering, not a second rule.
    var concentrationFactor: Double {
        if let recommended = recommendedLitresPerHectare, let actual = actualLitresPerHectare {
            return SprayCarrierConversion.concentrationFactor(dilute: recommended, actual: actual)
        }
        return SprayCarrierConversion.concentrationFactor(
            dilute: recommendedLitresPer100Metres,
            actual: actualLitresPer100Metres
        )
    }

    /// True once the operator has answered the question and a usable volume
    /// exists. `.useCustomSprayerRate` with an empty field is deliberately not
    /// resolved: the question has been opened, not answered.
    var isResolved: Bool { actualLitresPerHectare != nil || actualLitresPer100Metres != nil }

    /// True when the operator is concentrating — useful for presentation only.
    var isConcentrated: Bool { concentrationFactor > 1.0 }

    private func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

nonisolated enum SprayVolumeDecisionResolver {

    /// Builds the recommendation from the canopy, the vineyard's own table and
    /// canonical geometry. `nil` until the canopy has actually been answered —
    /// an unconfirmed canopy has no recommendation, only a picker position.
    static func recommendation(
        canopy: SprayCanopySelection,
        settings: CanopyWaterRateEntry,
        rowSpacingMetres: Double?
    ) -> SprayCanopyRecommendation? {
        guard let type = canopy.type, canopy.isConfirmed else { return nil }
        return SprayCanopyRecommendation(
            type: type,
            size: canopy.size,
            density: canopy.density,
            diluteLitresPer100Metres: CanopyWaterRate.litresPer100m(
                type: type,
                size: canopy.size,
                density: canopy.density,
                settings: settings
            ),
            rowSpacingMetres: rowSpacingMetres
        )
    }

    static func decide(
        canopy: SprayCanopySelection,
        settings: CanopyWaterRateEntry,
        rowSpacingMetres: Double?,
        choice: SprayVolumeChoice,
        customRate: Double?,
        customBasis: SprayCarrierBasis
    ) -> SprayVolumeDecision {
        SprayVolumeDecision(
            recommendation: recommendation(
                canopy: canopy,
                settings: settings,
                rowSpacingMetres: rowSpacingMetres
            ),
            choice: choice,
            customRate: customRate,
            customBasis: customBasis
        )
    }
}

/// The user-facing explanations for this decision path.
///
/// Held next to the model rather than inside a SwiftUI body so the wording is
/// one thing, testable, and cannot drift between the inline caption and the
/// info popover.
nonisolated enum SprayVolumeHelp {
    static let recommendedVolume = "This is VineTrack's estimated dilute spray volume for "
        + "the selected canopy. It is the reference volume at a concentration factor of 1.00."

    static let actualSprayerOutput = "Enter the water/carrier rate your sprayer is calibrated "
        + "to apply. This is your machine's spray volume, not the chemical label rate."

    static let concentrationFactor = "Compares the recommended dilute volume with the volume "
        + "your sprayer will actually apply. It is used to adjust products registered at a "
        + "rate per 100 L."

    static let sprayVolumeBasis = """
        Choose how your sprayer's application volume is expressed.

        L/100 m is the litres applied for each 100 metres of vine row.

        L/ha is the litres applied per hectare of vineyard area.

        VineTrack uses row spacing to convert between them where required.

        This does not change the registered rate or rate basis of any chemical.
        """

    /// The Unit Canopy Row model, behind the canopy-size info control.
    ///
    /// The AWRI diagram's printed per-hectare ranges are named as INDICATIVE
    /// here on purpose. They assume roughly 3 m rows and are rounded, so a
    /// 2.8 m vineyard reading them as a target would carry the wrong water.
    /// VineTrack derives the hectare figure from this block's own spacing.
    static let unitCanopyRow = """
        The canopy water rate is based on the Unit Canopy Row (UCR): a one-metre \
        by one-metre cross-section of canopy along 100 metres of row.

        Choose the picture whose canopy cross-section most closely matches the \
        block you are spraying. This describes the canopy, not the vineyard area.

        The AWRI diagram also shows indicative per-hectare ranges based on \
        approximately 3 m row spacing. VineTrack instead calculates the \
        equivalent from this vineyard's actual row spacing.
        """

    /// The bundled UCR diagram shown alongside `unitCanopyRow`.
    static let unitCanopyRowImageName = "canopy-ucr"
}
