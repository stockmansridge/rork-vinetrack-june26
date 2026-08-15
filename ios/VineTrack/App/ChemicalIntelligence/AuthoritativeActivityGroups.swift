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
    static let tableVersion: Int = 1

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
        if extracted.scheme == authoritative.scheme && extracted.code == authoritative.code {
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

        // ---- Herbicides (HRAC, global letter codes) ----
        "glyphosate": hrac("G", "EPSP synthase inhibitor"),
        "glufosinate": hrac("H", "Glutamine synthetase inhibitor"),
        "glufosinate ammonium": hrac("H", "Glutamine synthetase inhibitor"),
        "paraquat": hrac("D", "PSI electron diverter"),
        "diquat": hrac("D", "PSI electron diverter"),
        "simazine": hrac("C1", "PSII inhibitor"),
        "diuron": hrac("C2", "PSII inhibitor"),
        "amitrole": hrac("F3", "Carotenoid biosynthesis inhibitor"),
        "oxyfluorfen": hrac("E", "PPO inhibitor"),
        "carfentrazone": hrac("E", "PPO inhibitor"),
        "flumioxazin": hrac("E", "PPO inhibitor"),
        "haloxyfop": hrac("A", "ACCase inhibitor"),
        "clethodim": hrac("A", "ACCase inhibitor"),
        "fluazifop": hrac("A", "ACCase inhibitor"),
        "sethoxydim": hrac("A", "ACCase inhibitor"),
        "propyzamide": hrac("K1", "Microtubule assembly inhibitor"),
        "pendimethalin": hrac("K1", "Microtubule assembly inhibitor"),
        "trifluralin": hrac("K1", "Microtubule assembly inhibitor"),
        "isoxaben": hrac("L", "Cellulose synthesis inhibitor"),
        "indaziflam": hrac("L", "Cellulose synthesis inhibitor"),
        "metsulfuron methyl": hrac("B", "ALS inhibitor"),
        "chlorsulfuron": hrac("B", "ALS inhibitor"),
        "imazapyr": hrac("B", "ALS inhibitor"),
        "2,4 d": hrac("O", "Synthetic auxin"),
        "mcpa": hrac("O", "Synthetic auxin"),
        "triclopyr": hrac("O", "Synthetic auxin"),
        "clopyralid": hrac("O", "Synthetic auxin"),
        "pelargonic acid": hrac("Z", "Unknown / non-selective contact"),

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
