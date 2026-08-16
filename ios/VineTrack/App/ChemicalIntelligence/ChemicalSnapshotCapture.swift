import Foundation

/// The single way a NEW spray application freezes Chemical Intelligence onto a
/// product line.
///
/// Every path that creates a new application — the Spray Calculator, template
/// instantiation, a duplicate, a CSV import, a manual spray form — goes through
/// here. Screens must not resolve the Chemical Store and build snapshots
/// themselves: when three call sites each map intelligence their own way, they
/// drift, and the resistance history ends up meaning three different things
/// depending on which button the operator happened to press.
///
/// The two rules this type exists to enforce:
///
///  * **Current at application time.** Chemistry is read from the Chemical
///    Store as it stands NOW and frozen. Templates and imports are
///    configuration; they never carry stale chemistry forward.
///  * **Honest when unresolved.** A product that cannot be matched to a saved
///    chemical gets no invented actives, no authoritative groups, and no
///    Verified status — the absence is preserved so the Resistance Engine can
///    say "cannot assess" instead of "no concern".
nonisolated enum ChemicalSnapshotCapture {

    /// How a product line was matched to the Chemical Store, and what was
    /// frozen as a result.
    nonisolated struct Resolution: Sendable {
        /// The frozen chemistry, or `nil` when there was honestly nothing to
        /// freeze. `nil` is a legitimate outcome, never a bug to paper over.
        let snapshot: ChemicalLineSnapshot?
        /// The saved chemical this line is now linked to, if one was resolved.
        let savedChemicalId: UUID?
        /// How the link was established. Reported to the operator on import so
        /// unmatched products are visible rather than silently chemistry-less.
        let match: MatchKind

        var isResolved: Bool { savedChemicalId != nil }
    }

    /// Deterministic match strategies, in the order they are attempted.
    ///
    /// There is deliberately no fuzzy/partial name strategy: attaching
    /// authoritative chemistry to a product because its name merely resembled
    /// a library entry is how a resistance history quietly becomes fiction.
    nonisolated enum MatchKind: String, Sendable {
        /// Matched on an explicit saved-chemical id carried by the line.
        case identifier
        /// Matched on a country-scoped registration identity key.
        case registrationIdentity
        /// Matched on an exactly-equal (trimmed, case-insensitive) product name
        /// that is unique in the library.
        case exactName
        /// No safe match. Chemistry stays absent or legacy-only.
        case unresolved
    }

    // MARK: - Resolution

    /// Find the saved chemical a product line refers to, using only
    /// deterministic evidence.
    ///
    /// An exact name that matches two or more library entries is treated as
    /// ambiguous and left unresolved — picking "the first one" would attach one
    /// product's chemistry to another product's spray.
    /// - Parameter allowNameMatch: whether an exact unique NAME may establish the
    ///   link. `true` for importers, which have nothing but a name column.
    ///   `false` for screens where the operator either picked a product from the
    ///   Chemical Store or explicitly chose to enter one by hand — there a typed
    ///   string is a deliberate manual entry, and quietly binding it to a library
    ///   record would attach that record's chemistry to a product the operator
    ///   never selected.
    static func resolve(
        savedChemicalId: UUID?,
        productName: String?,
        registrationIdentityKey: String? = nil,
        in library: [SavedChemical],
        allowNameMatch: Bool = true
    ) -> (chemical: SavedChemical?, match: MatchKind) {
        // 1. Explicit identity always wins, including for archived products: a
        //    spray applied from an archived record still happened.
        if let savedChemicalId,
           let byId = library.first(where: { $0.id == savedChemicalId }) {
            return (byId, .identifier)
        }

        // 2. Country-scoped registration identity — as strong as an id, and the
        //    only cross-tenant-stable product key that exists.
        if let key = registrationIdentityKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            let matches = library.filter { $0.resolvedIntelligence.registration?.identityKey == key }
            if matches.count == 1 { return (matches[0], .registrationIdentity) }
        }

        // 3. Exact, unique display name.
        let name = (productName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if allowNameMatch, !name.isEmpty {
            let matches = library.filter {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(name) == .orderedSame
            }
            if matches.count == 1 { return (matches[0], .exactName) }
        }

        return (nil, .unresolved)
    }

    // MARK: - Capture

    /// Freeze one saved chemical's CURRENT intelligence.
    ///
    /// Reads `resolvedIntelligence`, so a product that was never structurally
    /// verified still contributes its legacy reading — sourced `.legacyRecord`
    /// and statused `.needsMatch`, which is exactly what Android freezes for
    /// the same product. Using the raw stored `chemicalIntelligence` here would
    /// make the two platforms write different JSON for identical data.
    static func capture(
        _ chemical: SavedChemical,
        at date: Date = Date()
    ) -> ChemicalLineSnapshot? {
        ChemicalLineSnapshot.capture(
            from: chemical.resolvedIntelligence,
            legacyChemicalGroup: chemical.chemicalGroup,
            // uuidString, not the UUID: the key must serialise identically to
            // Android's so one JSON shape covers both platforms.
            savedChemicalId: chemical.id.uuidString,
            productName: chemical.name,
            at: date
        )
    }

    /// The canonical entry point for a NEW application line.
    ///
    /// When the product resolves, today's chemistry is frozen. When it does
    /// not, any legacy group text the line itself carried is preserved as
    /// legacy-only evidence (unverified, schema 0, no actives), and if there is
    /// not even that, the snapshot is `nil`. Either way the line survives with
    /// its name and rate intact — losing the application would be a worse
    /// outcome than not knowing its chemistry.
    static func captureForNewApplication(
        savedChemicalId: UUID?,
        productName: String?,
        legacyChemicalGroup: String = "",
        registrationIdentityKey: String? = nil,
        library: [SavedChemical],
        at date: Date = Date(),
        allowNameMatch: Bool = true
    ) -> Resolution {
        let (chemical, match) = resolve(
            savedChemicalId: savedChemicalId,
            productName: productName,
            registrationIdentityKey: registrationIdentityKey,
            in: library,
            allowNameMatch: allowNameMatch
        )
        if let chemical {
            return Resolution(
                snapshot: capture(chemical, at: date),
                savedChemicalId: chemical.id,
                match: match
            )
        }
        return Resolution(
            snapshot: ChemicalLineSnapshot.capture(
                from: nil,
                legacyChemicalGroup: legacyChemicalGroup,
                savedChemicalId: nil,
                productName: (productName?.isEmpty ?? true) ? nil : productName,
                at: date
            ),
            savedChemicalId: nil,
            match: .unresolved
        )
    }
}
