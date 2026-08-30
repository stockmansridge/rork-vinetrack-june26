import Foundation

/// A curated, in-app classification of common viticultural active ingredients
/// to their FRAC / HRAC / IRAC activity groups.
///
/// This is VineTrack's `authoritativeClassification` source. It exists so that
/// an AI extraction is never the only opinion in the room: whatever the lookup
/// says an active's group is, it is checked against this table, and a
/// disagreement becomes a visible conflict rather than a silent overwrite.
///
/// Scope and honesty about it:
/// - It covers actives commonly used in Australian and New Zealand vineyards.
///   An active that is absent is simply UNKNOWN here — absence is never read as
///   "the extraction must be right".
/// - Activity group is a property of the ACTIVE, not of a brand, and it does
///   not vary by country. That is why this table needs no country dimension
///   while product identity emphatically does.
/// - Entries are keyed by the active's ISO common name, lower-cased.
///
/// The same table is mirrored in the `chemical-info-lookup` edge function and
/// on Android so all three agree; `tableVersion` is stamped onto every
/// verification so a future re-verification can tell which revision judged a
/// product.
nonisolated enum AuthoritativeActivityGroups {

    /// Bump whenever the table changes. Persisted with each verification.
    ///
    /// v2 — herbicides migrated from the legacy alphabetical codes to the
    /// CURRENT Australian/global numeric mode-of-action groups, with
    /// per-active legacy equivalence (see `legacyCodes`). Completed spray
    /// snapshots are never rewritten: they keep the classification that was
    /// current when they were recorded. Saved chemicals pick the current group
    /// up through the normal Re-verify path.
    static let tableVersion: Int = 2

    /// The source citation recorded when this table supplies a group.
    static func source(retrievedAt: Date? = nil) -> ChemicalDataSource {
        ChemicalDataSource(
            kind: .authoritativeClassification,
            name: "VineTrack activity group reference v\(tableVersion) (FRAC/HRAC/IRAC)",
            reference: nil,
            retrievedAt: retrievedAt
        )
    }

    /// Look up an active's authoritative group.
    ///
    /// Returns `nil` when the active is not in the table — which means
    /// "unknown", never "unclassified". Callers must not treat `nil` as
    /// permission to trust an unverified extraction.
    static func group(forActiveNamed name: String) -> ChemicalActivityGroup? {
        let key = normalise(name)
        guard !key.isEmpty else { return nil }
        if let exact = table[key] { return exact }
        // Salt/ester forms are written many ways ("glyphosate isopropylamine",
        // "mancozeb + zoxamide"). Match the longest known active contained in
        // the string so a formulation suffix does not lose the classification.
        let candidates = table.keys
            .filter { key.contains($0) && $0.count >= 5 }
            .sorted { $0.count > $1.count }
        guard let best = candidates.first else { return nil }
        return table[best]
    }

    /// Whether the table has an opinion about this active at all.
    static func knows(activeNamed name: String) -> Bool {
        group(forActiveNamed: name) != nil
    }

    /// Cross-checks an extracted group against the authoritative table.
    ///
    /// This is the Phase 7 gate in one function:
    /// - No authoritative opinion → returns the extracted group unchanged and
    ///   no conflict, but the caller must NOT call the result authoritative.
    /// - Agreement → the authoritative group wins (same code, better source).
    /// - Disagreement → returns the AUTHORITATIVE group plus a conflict. The
    ///   extracted value never silently survives.
    static func reconcile(
        activeNamed name: String,
        extracted: ChemicalActivityGroup?,
        extractedSource: ChemicalDataSourceKind
    ) -> (group: ChemicalActivityGroup?, source: ChemicalDataSourceKind?, conflict: ChemicalVerificationConflict?) {
        guard let authoritative = group(forActiveNamed: name) else {
            // Unknown to the table: keep what we have, but its source — and so
            // its trust level — is unchanged.
            return (extracted, extracted == nil ? nil : extractedSource, nil)
        }
        guard let extracted, extracted.isResistanceRelevant else {
            return (authoritative, .authoritativeClassification, nil)
        }
        // Canonical identity, not string identity: a legacy code for this
        // active is the SAME classification, so it agrees rather than
        // conflicts. The CURRENT group is served either way — growers see
        // today's number, never the code a historical source happened to use.
        if Self.groupsAreEquivalent(activeNamed: name, extracted, authoritative) {
            return (authoritative, .authoritativeClassification, nil)
        }
        let conflict = ChemicalVerificationConflict(
            field: "activity_group",
            activeIngredientName: name,
            extractedValue: extracted.displayLabel,
            authoritativeValue: authoritative.displayLabel,
            extractedSource: extractedSource,
            authoritativeSource: .authoritativeClassification
        )
        return (authoritative, .authoritativeClassification, conflict)
    }

    private static func normalise(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private static func frac(_ code: String, _ name: String) -> ChemicalActivityGroup {
        ChemicalActivityGroup(scheme: .frac, code: code, commonName: name)
    }

    private static func hrac(_ code: String, _ name: String) -> ChemicalActivityGroup {
        ChemicalActivityGroup(scheme: .hrac, code: code, commonName: name)
    }

    /// Every code a herbicide active was legitimately published under BEFORE
    /// the current numeric classification.
    ///
    /// # Why equivalence is per ACTIVE and never per letter
    ///
    /// Australia replaced the alphabetical herbicide mode-of-action codes with
    /// the globally aligned NUMERIC system; labels carried numbers from 2022
    /// and the transition completed in 2024. So a current label says
    /// "Group 14" where an older one said "Group E" (old global HRAC) or
    /// "Group G" (old Australian) — one classification, three vocabularies.
    ///
    /// The two legacy alphabets reuse the same characters for different
    /// chemistries: "E" was PPO inhibitors globally but carbamates in
    /// Australia, "G" was glyphosate globally but PPO inhibitors in Australia.
    /// A letter on its own is therefore not decodable; a letter plus the
    /// active it was printed for always is.
    ///
    /// Mirrored byte-for-byte in the edge function and on Android.
    private static let legacyHRACCodes: [String: [String]] = [
        "glyphosate": ["G", "M"],
        "glufosinate": ["H", "N"],
        "glufosinate ammonium": ["H", "N"],
        "paraquat": ["D", "L"],
        "diquat": ["D", "L"],
        "simazine": ["C1", "C"],
        "diuron": ["C2", "C"],
        "amitrole": ["F3", "Q"],
        "oxyfluorfen": ["E", "G"],
        "carfentrazone": ["E", "G"],
        "flumioxazin": ["E", "G"],
        "haloxyfop": ["A"],
        "clethodim": ["A"],
        "fluazifop": ["A"],
        "sethoxydim": ["A"],
        "propyzamide": ["K1", "D"],
        "pendimethalin": ["K1", "D"],
        "trifluralin": ["K1", "D"],
        "isoxaben": ["L", "O"],
        "indaziflam": ["L", "O"],
        "metsulfuron methyl": ["B"],
        "chlorsulfuron": ["B"],
        "imazapyr": ["B"],
        "2,4 d": ["O", "I"],
        "mcpa": ["O", "I"],
        "triclopyr": ["O", "I"],
        "clopyralid": ["O", "I"],
        "pelargonic acid": ["Z"]
    ]

    /// Every herbicide active this table classifies, by its table key.
    ///
    /// Exposed so the shared contract tests can assert the RULE across the
    /// whole herbicide table rather than spot-checking one product — a
    /// classification that is only right for the active someone remembered to
    /// test is not a classification anyone should trust.
    static var herbicideActiveNames: [String] {
        table.filter { $0.value.scheme == .hrac }.map(\.key).sorted()
    }

    /// Strip the decoration humans, labels and extractions put around a code so
    /// `"Group 14"`, `"group14"` and `"14 (PPO inhibitor)"` all reduce to `14`.
    static func normaliseCode(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for prefix in ["GROUP ", "GROUP", "FRAC ", "HRAC ", "IRAC ", "MOA ", "CODE "] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if let paren = value.firstIndex(of: "(") {
            value = String(value[value.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return value.replacingOccurrences(of: " ", with: "")
    }

    /// Legacy codes recorded for this active, normalised. Empty for actives
    /// with no legacy alphabet (fungicides, insecticides) and unknown actives.
    static func legacyCodes(forActiveNamed name: String) -> [String] {
        let key = normalise(name)
        guard !key.isEmpty else { return [] }
        if let direct = legacyHRACCodes[key] { return direct.map(normaliseCode) }
        // The same longest-contained-active rule `group(forActiveNamed:)` uses,
        // so a salt or ester form inherits its parent's legacy codes too.
        let candidates = legacyHRACCodes.keys
            .filter { key.contains($0) && $0.count >= 5 }
            .sorted { $0.count > $1.count }
        guard let best = candidates.first else { return [] }
        return legacyHRACCodes[best]?.map(normaliseCode) ?? []
    }

    /// Whether two classifications of the SAME active mean the same thing.
    ///
    /// This is the canonical-identity comparison the v2 migration turns on. A
    /// label printed before the numeric realignment says "Group E" for exactly
    /// the chemistry a current label calls "Group 14". Reporting those to a
    /// grower as sources that disagree is a false alarm about a resistance
    /// group — the one place in the app where a false alarm costs most trust.
    ///
    /// A genuine disagreement — a source calling flumioxazin a Group 2 — still
    /// conflicts, which is the entire point of keeping the check.
    static func groupsAreEquivalent(
        activeNamed name: String,
        _ a: ChemicalActivityGroup?,
        _ b: ChemicalActivityGroup?
    ) -> Bool {
        guard let a, let b, a.scheme == b.scheme else { return false }
        let codeA = normaliseCode(a.code)
        let codeB = normaliseCode(b.code)
        guard !codeA.isEmpty, !codeB.isEmpty else { return false }
        if codeA == codeB { return true }
        guard a.scheme == .hrac else { return false }
        let legacy = legacyCodes(forActiveNamed: name)
        guard !legacy.isEmpty else { return false }
        let current = normaliseCode(group(forActiveNamed: name)?.code ?? "")
        guard !current.isEmpty else { return false }
        let isCurrentOrLegacy: (String) -> Bool = { $0 == current || legacy.contains($0) }
        return isCurrentOrLegacy(codeA) && isCurrentOrLegacy(codeB)
    }

    private static func irac(_ code: String, _ name: String) -> ChemicalActivityGroup {
        ChemicalActivityGroup(scheme: .irac, code: code, commonName: name)
    }

    /// Active (lower-case ISO common name) → activity group.
    private static let table: [String: ChemicalActivityGroup] = [
        // ---- Fungicides (FRAC) ----
        // DMI / triazoles
        "tebuconazole": frac("3", "DMI / Triazole"),
        "myclobutanil": frac("3", "DMI / Triazole"),
        "penconazole": frac("3", "DMI / Triazole"),
        "triadimenol": frac("3", "DMI / Triazole"),
        "tetraconazole": frac("3", "DMI / Triazole"),
        "difenoconazole": frac("3", "DMI / Triazole"),
        "propiconazole": frac("3", "DMI / Triazole"),
        "flutriafol": frac("3", "DMI / Triazole"),
        "triflumizole": frac("3", "DMI / Imidazole"),
        "prochloraz": frac("3", "DMI / Imidazole"),
        "fenarimol": frac("3", "DMI / Pyrimidine"),
        // Phenylamides
        "metalaxyl": frac("4", "Phenylamide"),
        "metalaxyl m": frac("4", "Phenylamide"),
        "mefenoxam": frac("4", "Phenylamide"),
        "benalaxyl": frac("4", "Phenylamide"),
        // Amines / morpholines
        "spiroxamine": frac("5", "Amine / Morpholine"),
        "dimethomorph": frac("40", "CAA"),
        "mandipropamid": frac("40", "CAA"),
        "benthiavalicarb": frac("40", "CAA"),
        "iprovalicarb": frac("40", "CAA"),
        // MBC
        "carbendazim": frac("1", "MBC / Benzimidazole"),
        "thiophanate methyl": frac("1", "MBC / Thiophanate"),
        // Dicarboximides
        "iprodione": frac("2", "Dicarboximide"),
        "procymidone": frac("2", "Dicarboximide"),
        // AP fungicides
        "cyprodinil": frac("9", "Anilinopyrimidine"),
        "pyrimethanil": frac("9", "Anilinopyrimidine"),
        "mepanipyrim": frac("9", "Anilinopyrimidine"),
        // QoI / strobilurins
        "azoxystrobin": frac("11", "QoI / Strobilurin"),
        "trifloxystrobin": frac("11", "QoI / Strobilurin"),
        "pyraclostrobin": frac("11", "QoI / Strobilurin"),
        "kresoxim methyl": frac("11", "QoI / Strobilurin"),
        "famoxadone": frac("11", "QoI"),
        "fenamidone": frac("11", "QoI"),
        // Phenylpyrroles
        "fludioxonil": frac("12", "Phenylpyrrole"),
        // Quinolines
        "quinoxyfen": frac("13", "Aza-naphthalene"),
        // SDHI
        "boscalid": frac("7", "SDHI"),
        "fluopyram": frac("7", "SDHI"),
        "fluxapyroxad": frac("7", "SDHI"),
        "penthiopyrad": frac("7", "SDHI"),
        "isopyrazam": frac("7", "SDHI"),
        "benzovindiflupyr": frac("7", "SDHI"),
        "pydiflumetofen": frac("7", "SDHI"),
        // Hydroxyanilides / SBI class III
        "fenhexamid": frac("17", "Hydroxyanilide"),
        // QiI
        "cyazofamid": frac("21", "QiI"),
        "amisulbrom": frac("21", "QiI"),
        // Others
        "metrafenone": frac("U8", "Aryl-phenyl-ketone"),
        "pyriofenone": frac("U8", "Aryl-phenyl-ketone"),
        "cyflufenamid": frac("U6", "Phenyl-acetamide"),
        "proquinazid": frac("13", "Quinazolinone"),
        "fluazinam": frac("29", "Uncoupler"),
        "ametoctradin": frac("45", "QoSI"),
        "oxathiapiprolin": frac("49", "OSBPI"),
        "fluopicolide": frac("43", "Benzamide"),
        "zoxamide": frac("22", "Benzamide"),
        "phosphorous acid": frac("P07", "Host defence induction"),
        "phosphonic acid": frac("P07", "Host defence induction"),
        "potassium phosphonate": frac("P07", "Host defence induction"),
        "fosetyl aluminium": frac("P07", "Host defence induction"),
        "fosetyl al": frac("P07", "Host defence induction"),
        // Multi-site
        "sulfur": frac("M2", "Multi-site / Inorganic"),
        "sulphur": frac("M2", "Multi-site / Inorganic"),
        "copper hydroxide": frac("M1", "Multi-site / Copper"),
        "copper oxychloride": frac("M1", "Multi-site / Copper"),
        "cuprous oxide": frac("M1", "Multi-site / Copper"),
        "tribasic copper sulfate": frac("M1", "Multi-site / Copper"),
        "mancozeb": frac("M3", "Multi-site / Dithiocarbamate"),
        "metiram": frac("M3", "Multi-site / Dithiocarbamate"),
        "propineb": frac("M3", "Multi-site / Dithiocarbamate"),
        "ziram": frac("M3", "Multi-site / Dithiocarbamate"),
        "thiram": frac("M3", "Multi-site / Dithiocarbamate"),
        "captan": frac("M4", "Multi-site / Phthalimide"),
        "folpet": frac("M4", "Multi-site / Phthalimide"),
        "chlorothalonil": frac("M5", "Multi-site / Chloronitrile"),
        "dithianon": frac("M9", "Multi-site / Quinone"),

        // ---- Herbicides (current Australian/global numeric MoA groups) ----
        // Legacy equivalents live in `legacyHRACCodes`, keyed by the same name.
        "glyphosate": hrac("9", "EPSP synthase inhibitor"),
        "glufosinate": hrac("10", "Glutamine synthetase inhibitor"),
        "glufosinate ammonium": hrac("10", "Glutamine synthetase inhibitor"),
        "paraquat": hrac("22", "PSI electron diverter"),
        "diquat": hrac("22", "PSI electron diverter"),
        "simazine": hrac("5", "PSII inhibitor (serine 264 binder)"),
        "diuron": hrac("5", "PSII inhibitor (serine 264 binder)"),
        "amitrole": hrac("34", "Lycopene cyclase inhibitor"),
        "oxyfluorfen": hrac("14", "PPO inhibitor"),
        "carfentrazone": hrac("14", "PPO inhibitor"),
        "flumioxazin": hrac("14", "PPO inhibitor"),
        "haloxyfop": hrac("1", "ACCase inhibitor"),
        "clethodim": hrac("1", "ACCase inhibitor"),
        "fluazifop": hrac("1", "ACCase inhibitor"),
        "sethoxydim": hrac("1", "ACCase inhibitor"),
        "propyzamide": hrac("3", "Microtubule assembly inhibitor"),
        "pendimethalin": hrac("3", "Microtubule assembly inhibitor"),
        "trifluralin": hrac("3", "Microtubule assembly inhibitor"),
        "isoxaben": hrac("29", "Cellulose synthesis inhibitor"),
        "indaziflam": hrac("29", "Cellulose synthesis inhibitor"),
        "metsulfuron methyl": hrac("2", "ALS inhibitor"),
        "chlorsulfuron": hrac("2", "ALS inhibitor"),
        "imazapyr": hrac("2", "ALS inhibitor"),
        "2,4 d": hrac("4", "Auxin mimic"),
        "mcpa": hrac("4", "Auxin mimic"),
        "triclopyr": hrac("4", "Auxin mimic"),
        "clopyralid": hrac("4", "Auxin mimic"),
        "pelargonic acid": hrac("0", "Unknown / non-selective contact"),

        // ---- Insecticides & miticides (IRAC) ----
        "chlorpyrifos": irac("1B", "Organophosphate"),
        "methomyl": irac("1A", "Carbamate"),
        "alpha cypermethrin": irac("3A", "Pyrethroid"),
        "bifenthrin": irac("3A", "Pyrethroid"),
        "lambda cyhalothrin": irac("3A", "Pyrethroid"),
        "deltamethrin": irac("3A", "Pyrethroid"),
        "esfenvalerate": irac("3A", "Pyrethroid"),
        "imidacloprid": irac("4A", "Neonicotinoid"),
        "thiamethoxam": irac("4A", "Neonicotinoid"),
        "acetamiprid": irac("4A", "Neonicotinoid"),
        "clothianidin": irac("4A", "Neonicotinoid"),
        "spinetoram": irac("5", "Spinosyn"),
        "spinosad": irac("5", "Spinosyn"),
        "abamectin": irac("6", "Avermectin"),
        "emamectin benzoate": irac("6", "Avermectin"),
        "buprofezin": irac("16", "Chitin biosynthesis inhibitor"),
        "methoxyfenozide": irac("18", "Diacylhydrazine"),
        "tebufenozide": irac("18", "Diacylhydrazine"),
        "etoxazole": irac("10B", "Mite growth inhibitor"),
        "clofentezine": irac("10A", "Mite growth inhibitor"),
        "hexythiazox": irac("10A", "Mite growth inhibitor"),
        "propargite": irac("12C", "METI / Sulfite ester"),
        "fenbutatin oxide": irac("12B", "Organotin miticide"),
        "bifenazate": irac("20D", "Mitochondrial complex III inhibitor"),
        "chlorantraniliprole": irac("28", "Diamide"),
        "cyantraniliprole": irac("28", "Diamide"),
        "flubendiamide": irac("28", "Diamide"),
        "sulfoxaflor": irac("4C", "Sulfoximine"),
        "spirotetramat": irac("23", "Tetramic acid"),
        "spirodiclofen": irac("23", "Tetronic acid"),
        "pyriproxyfen": irac("7C", "Juvenile hormone mimic"),
        "indoxacarb": irac("22A", "Oxadiazine"),
        "bacillus thuringiensis": irac("11A", "Bt / Microbial disruptor"),
    ]
}
