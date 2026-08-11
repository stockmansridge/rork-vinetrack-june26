import Foundation

/// Shared per-block Pruning Yield Calculator configuration
/// (`public.pruning_yield_settings`, sql/181).
///
/// ONE record per vineyard block, upserted on (vineyard_id, paddock_id).
/// Only the INPUT ASSUMPTIONS are persisted — every calculated output
/// (buds/vine, bunches/ha, yield kg/ha, yield t/ha, block total tonnes) is
/// derived with `YieldDeterminationFormula` so results can never go stale.
nonisolated struct PruningYieldSettings: Codable, Identifiable, Hashable {
    var id: UUID
    var vineyardId: UUID
    var paddockId: UUID
    /// Canonical lowercase `"spur"` | `"cane"` (matches the SQL contract).
    var pruneMethod: String
    var bunchesPerBud: Double
    var budsPerSpur: Double
    var spursPerVine: Double
    var budsPerCane: Double
    var canesPerVine: Double
    /// Nil = not set; clients seed it from the block's vine count ÷ area.
    var vinesPerHa: Double?
    var bunchWeightGrams: Double
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        paddockId: UUID,
        pruneMethod: String = PruningYieldDefaults.pruneMethod,
        bunchesPerBud: Double = PruningYieldDefaults.bunchesPerBud,
        budsPerSpur: Double = PruningYieldDefaults.budsPerSpur,
        spursPerVine: Double = PruningYieldDefaults.spursPerVine,
        budsPerCane: Double = PruningYieldDefaults.budsPerCane,
        canesPerVine: Double = PruningYieldDefaults.canesPerVine,
        vinesPerHa: Double? = nil,
        bunchWeightGrams: Double = PruningYieldDefaults.bunchWeightGrams,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        self.pruneMethod = pruneMethod
        self.bunchesPerBud = bunchesPerBud
        self.budsPerSpur = budsPerSpur
        self.spursPerVine = spursPerVine
        self.budsPerCane = budsPerCane
        self.canesPerVine = canesPerVine
        self.vinesPerHa = vinesPerHa
        self.bunchWeightGrams = bunchWeightGrams
        self.updatedAt = updatedAt
    }

    /// Value equality on the user-editable inputs only (identity, vineyard,
    /// block and timestamps ignored). Used to skip no-op autosaves.
    func inputsEqual(to other: PruningYieldSettings) -> Bool {
        pruneMethod == other.pruneMethod
            && bunchesPerBud == other.bunchesPerBud
            && budsPerSpur == other.budsPerSpur
            && spursPerVine == other.spursPerVine
            && budsPerCane == other.budsPerCane
            && canesPerVine == other.canesPerVine
            && vinesPerHa == other.vinesPerHa
            && bunchWeightGrams == other.bunchWeightGrams
    }
}

/// Canonical defaults for an unsaved block — identical on iOS, Android and
/// the SQL column defaults (sql/181).
nonisolated enum PruningYieldDefaults {
    static let pruneMethod = "spur"
    static let bunchesPerBud: Double = 1.5
    static let budsPerSpur: Double = 2
    static let spursPerVine: Double = 6
    static let budsPerCane: Double = 10
    static let canesPerVine: Double = 4
    static let bunchWeightGrams: Double = 120
}

/// Text <-> number conversion shared by the calculator UI and the legacy
/// migration, so "1.5", "2" and "120" round-trip identically on both
/// platforms (no locale grouping, dot decimal, trailing zeros trimmed).
nonisolated enum PruningYieldInputFormat {
    /// Parse a user-entered decimal ("," accepted as decimal separator).
    static func parse(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// Parse an optional field: blank / unparseable = nil.
    static func parseOptional(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let value = Double(trimmed.replacingOccurrences(of: ",", with: "."))
        return value
    }

    /// Format a stored number back into field text: "2" not "2.0", "1.5",
    /// up to 4 decimal places, never grouped.
    static func text(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1_000_000_000 {
            return String(format: "%.0f", value)
        }
        var s = String(format: "%.4f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func text(_ value: Double?) -> String {
        guard let value else { return "" }
        return text(value)
    }
}

/// Shape of the pre-sql/181 device-local save
/// (`UserDefaults` key `vinetrack_yield_determination_{userId}_{paddockId}`,
/// raw field text). Kept only to migrate existing users' saved values into
/// the shared contract — never written any more.
nonisolated struct LegacyPruningCalculatorSettings: Codable {
    var pruneMethod: String
    var bunchesPerBud: String
    var budsPerSpur: String
    var spursPerVine: String
    var budsPerCane: String
    var canesPerVine: String
    var vinesPerHa: String
    var bunchWeight: String
}

extension PruningYieldSettings {
    /// UserDefaults key of the legacy device-local per-block save.
    static func legacyDefaultsKey(userId: String, paddockId: UUID) -> String {
        "vinetrack_yield_determination_\(userId)_\(paddockId.uuidString)"
    }

    /// Read the legacy device-local save for a block, if one exists.
    @MainActor
    static func legacySettings(userId: String?, paddockId: UUID) -> LegacyPruningCalculatorSettings? {
        guard let userId else { return nil }
        let key = legacyDefaultsKey(userId: userId, paddockId: paddockId)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LegacyPruningCalculatorSettings.self, from: data)
    }

    /// Convert a legacy device-local save into the shared contract shape.
    static func fromLegacy(
        _ legacy: LegacyPruningCalculatorSettings,
        vineyardId: UUID,
        paddockId: UUID
    ) -> PruningYieldSettings {
        PruningYieldSettings(
            vineyardId: vineyardId,
            paddockId: paddockId,
            pruneMethod: legacy.pruneMethod.lowercased() == "cane" ? "cane" : "spur",
            bunchesPerBud: PruningYieldInputFormat.parse(legacy.bunchesPerBud),
            budsPerSpur: PruningYieldInputFormat.parse(legacy.budsPerSpur),
            spursPerVine: PruningYieldInputFormat.parse(legacy.spursPerVine),
            budsPerCane: PruningYieldInputFormat.parse(legacy.budsPerCane),
            canesPerVine: PruningYieldInputFormat.parse(legacy.canesPerVine),
            vinesPerHa: PruningYieldInputFormat.parseOptional(legacy.vinesPerHa),
            bunchWeightGrams: PruningYieldInputFormat.parse(legacy.bunchWeight)
        )
    }
}
