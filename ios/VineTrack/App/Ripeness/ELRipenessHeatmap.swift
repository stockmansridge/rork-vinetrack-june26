import Foundation

/// Pure, deterministic mirror of the shipped VineTrack Portal E-L Ripeness
/// Heatmap calculation (cross-platform contract v1.0.0).
///
/// Every rule here is a direct transcription of the contract's Appendix A
/// reference implementation. It is intentionally free of UI, storage and
/// networking so it can be pinned by the shared fixture on both platforms.
/// The Kotlin mirror `ElRipenessHeatmap` must stay numerically identical.
///
/// Deliberate quirks reproduced verbatim (they are contract, not accident):
/// * JavaScript `Number()` parsing semantics, including hexadecimal literals.
/// * Day arithmetic on the ISO string's own date component, with **no**
///   timezone conversion.
/// * Distance in "cosine-corrected degrees" using the *cell* latitude, while
///   the bounding-box diagonal uses the box's `minLat`.
/// * E-L 47 is excluded, never clamped to E-L 43.
nonisolated enum ELRipeness {

    // MARK: - Constants (contract section 0)

    static let elMin: Double = 1
    static let elMax: Double = 43
    static let recencyHalfLifeDays: Double = 21
    static let recencyMaxAgeDays: Double = 84
    static let recencyTaperDays: Double = 14
    static let idwPower: Double = 2
    static let gridResolution: Int = 48
    static let maxAlpha: Double = 0.72
    static let minAlphaFactor: Double = 0.12
    static let haloFraction: Double = 0.22
    static let gradientFraction: Double = 0.35
    static let zeroDistanceEpsilonD2: Double = 1e-14

    // MARK: - Colour

    nonisolated struct RGB: Equatable, Sendable {
        let r: Int
        let g: Int
        let b: Int

        var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
    }

    nonisolated struct ColourStop: Sendable {
        let el: Double
        let rgb: RGB
        let label: String
    }

    static let colourStops: [ColourStop] = [
        ColourStop(el: 1, rgb: RGB(r: 220, g: 38, b: 38), label: "EL 1 — dormant"),
        ColourStop(el: 12, rgb: RGB(r: 234, g: 129, b: 24), label: "EL 12 — early development"),
        ColourStop(el: 23, rgb: RGB(r: 234, g: 199, b: 24), label: "EL 23 — mid-season"),
        ColourStop(el: 35, rgb: RGB(r: 132, g: 204, b: 22), label: "EL 35 — advanced"),
        ColourStop(el: 43, rgb: RGB(r: 22, g: 143, b: 60), label: "EL 43 — harvest ripe"),
    ]

    /// ECMAScript `Math.round`: half-up toward +∞ (not away-from-zero).
    static func jsRound(_ value: Double) -> Double {
        (value + 0.5).rounded(.down)
    }

    static func clamp(_ n: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, n))
    }

    /// Piecewise linear interpolation in non-linear sRGB 8-bit space. No
    /// linear-light conversion, no HSL, no Lab — plain channel mixing on the
    /// stored 0–255 values, exactly as the Portal ships it.
    static func elColour(_ el: Double) -> RGB {
        let v = clamp(el, elMin, elMax)
        guard let first = colourStops.first, let last = colourStops.last else {
            return RGB(r: 0, g: 0, b: 0)
        }
        if v <= first.el { return first.rgb }
        for index in 1..<colourStops.count {
            let prev = colourStops[index - 1]
            let cur = colourStops[index]
            if v <= cur.el {
                let t = (v - prev.el) / (cur.el - prev.el)
                return RGB(
                    r: Int(jsRound(Double(prev.rgb.r) + Double(cur.rgb.r - prev.rgb.r) * t)),
                    g: Int(jsRound(Double(prev.rgb.g) + Double(cur.rgb.g - prev.rgb.g) * t)),
                    b: Int(jsRound(Double(prev.rgb.b) + Double(cur.rgb.b - prev.rgb.b) * t))
                )
            }
        }
        return last.rgb
    }

    /// Contract section 6. The 0.12 floor applies only to cells that have a
    /// value; a `nil` cell is always fully transparent.
    static func alpha255(cellWeight: Double?) -> Int {
        guard let weight = cellWeight else { return Int(jsRound(255 * maxAlpha * 1)) }
        return Int(jsRound(255 * maxAlpha * clamp(weight, minAlphaFactor, 1)))
    }

    /// Alpha for a rendered cell: `nil` value → fully transparent.
    static func alpha255(value: Double?, cellWeight: Double?) -> Int {
        guard value != nil else { return 0 }
        return alpha255(cellWeight: cellWeight)
    }

    // MARK: - E-L parsing (contract section 1)

    /// JavaScript `Number(String)` semantics. Returns `nil` for `NaN`.
    ///
    /// Accepts decimals, a leading sign, exponent form, `Infinity`, and
    /// hexadecimal / octal / binary literals. Rejects internal whitespace and
    /// trailing characters. An empty string is `0`, matching JavaScript.
    static func jsNumber(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return 0 }
        if s == "Infinity" || s == "+Infinity" { return .infinity }
        if s == "-Infinity" { return -.infinity }

        // Radix literals carry no sign in JavaScript.
        if s.count > 2, s.hasPrefix("0") {
            let marker = s[s.index(s.startIndex, offsetBy: 1)]
            let digits = String(s.dropFirst(2))
            let radix: Int?
            switch marker {
            case "x", "X": radix = 16
            case "o", "O": radix = 8
            case "b", "B": radix = 2
            default: radix = nil
            }
            if let radix {
                guard let value = UInt64(digits, radix: radix) else { return nil }
                return Double(value)
            }
        }

        guard isStrictDecimalLiteral(s), let value = Double(s) else { return nil }
        return value
    }

    /// `/^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/` — deliberately stricter
    /// than `Double(_:)`, which would accept "nan", "0x1p3" and similar.
    private static func isStrictDecimalLiteral(_ s: String) -> Bool {
        var chars = Array(s)
        var i = 0
        if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
        var intDigits = 0
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; intDigits += 1 }
        var fracDigits = 0
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; fracDigits += 1 }
        }
        if intDigits == 0 && fracDigits == 0 { return false }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            i += 1
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            var expDigits = 0
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; expDigits += 1 }
            if expDigits == 0 { return false }
        }
        return i == chars.count
    }

    /// Parses a stored growth-stage code to an E-L value in `[1, 43]`.
    ///
    /// **E-L 47 returns `nil`.** It is outside the ripeness heat surface and is
    /// never clamped to E-L 43; it remains available to the Summary report,
    /// which does not use this function.
    static func parseElStage(_ code: String?) -> Double? {
        guard let code else { return nil }
        let s = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        // Strip only a LEADING E-L prefix: /^e\s*-?\s*l\s*/i
        var cleaned = s
        if let stripped = strippedElPrefix(s) { cleaned = stripped }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let n = jsNumber(cleaned), n.isFinite else { return nil }
        if n < elMin || n > elMax { return nil }
        return n
    }

    private static func strippedElPrefix(_ s: String) -> String? {
        var chars = Array(s)
        var i = 0
        guard i < chars.count, chars[i] == "e" || chars[i] == "E" else { return nil }
        i += 1
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        if i < chars.count, chars[i] == "-" { i += 1 }
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count, chars[i] == "l" || chars[i] == "L" else { return nil }
        i += 1
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        return String(chars[i...])
    }

    /// Display formatting: integers as `E-L 23`, non-integers to one decimal,
    /// `nil` as an em dash.
    static func formatEl(_ el: Double?) -> String {
        guard let el else { return "—" }
        if el == el.rounded() && el.magnitude < 1e15 {
            return "E-L \(Int(el))"
        }
        return "E-L \(String(format: "%.1f", el))"
    }

    // MARK: - Dates and recency (contract section 3)

    /// The calendar-day key: the first 10 characters of the ISO string. A pure
    /// slice — no timezone conversion is performed at any point.
    static func dayKey(_ iso: String) -> String {
        String(iso.prefix(10))
    }

    /// Whole-day difference between two day keys. Both endpoints are treated as
    /// start-of-day, so the result is always an integer number of days. There
    /// is no elapsed-time or fractional-day component. Unparseable input is 0.
    static func daysBetween(_ fromISO: String, _ toISO: String) -> Int {
        guard let a = CivilDate(dayKey: dayKey(fromISO)),
              let b = CivilDate(dayKey: dayKey(toISO)) else { return 0 }
        return b.epochDay - a.epochDay
    }

    /// `decay * taper`, zero at and beyond 84 days. The taper only engages
    /// after day 70, which is why day 70 is pure exponential decay.
    static func recencyWeight(ageDays: Double) -> Double {
        let age = max(0, ageDays)
        if age >= recencyMaxAgeDays { return 0 }
        let decay = pow(0.5, age / recencyHalfLifeDays)
        let taper = clamp((recencyMaxAgeDays - age) / recencyTaperDays, 0, 1)
        return decay * taper
    }

    static func recencyWeight(ageDays: Int) -> Double {
        recencyWeight(ageDays: Double(ageDays))
    }

    // MARK: - Observations

    /// A growth-stage record as read from `v_growth_stage_observations` (or the
    /// `pins` fallback), before normalisation. Keeps the raw stage code and all
    /// three timestamp candidates so the offline cache can re-normalise.
    nonisolated struct RawRecord: Equatable, Sendable {
        let id: String
        /// Owning vineyard. Every query is scoped to the selected vineyard, so a
        /// record from another vineyard is `wrong_vineyard` — never a date error.
        let vineyardId: String?
        let paddockId: String?
        let stageCode: String?
        let latitude: Double?
        let longitude: Double?
        let date: String?
        let observedAt: String?
        let completedAt: String?
        let createdAt: String?
        let deletedAt: String?

        init(
            id: String,
            vineyardId: String? = nil,
            paddockId: String? = nil,
            stageCode: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            date: String? = nil,
            observedAt: String? = nil,
            completedAt: String? = nil,
            createdAt: String? = nil,
            deletedAt: String? = nil
        ) {
            self.id = id
            self.vineyardId = vineyardId
            self.paddockId = paddockId
            self.stageCode = stageCode
            self.latitude = latitude
            self.longitude = longitude
            self.date = date
            self.observedAt = observedAt
            self.completedAt = completedAt
            self.createdAt = createdAt
            self.deletedAt = deletedAt
        }
    }

    /// A normalised observation that survived every exclusion rule.
    nonisolated struct Observation: Equatable, Sendable {
        let id: String
        let paddockId: String?
        let assigned: Bool
        let el: Double
        let lat: Double
        let lng: Double
        let dateISO: String
    }

    /// Why a raw record never became an observation. Mirrors the
    /// `excluded_reason` values in the contract's expected file.
    nonisolated enum ExclusionReason: String, Equatable, Sendable {
        /// Contract 1.1.0 section 10: the record belongs to a different vineyard
        /// and is never fetched. This is *not* a date error — such records may
        /// carry perfectly valid dates and a valid Vintage under their own
        /// vineyard's season settings.
        case wrongVineyard = "wrong_vineyard"
        case deleted
        case elOutOfRangeOrUnparseable = "el_out_of_range_or_unparseable"
        case missingCoordinates = "missing_coordinates"
        /// Used only when `date`, `observed_at`, `completed_at` and `created_at` are absent.
        case noObservationDate = "no_observation_date"
    }

    /// Observation timestamp precedence: `date` → `observed_at` →
    /// `completed_at` → `created_at`. `updated_at` is **never** used.
    static func observationDate(_ record: RawRecord) -> String? {
        if let d = record.date, !d.isEmpty { return d }
        if let d = record.observedAt, !d.isEmpty { return d }
        if let d = record.completedAt, !d.isEmpty { return d }
        if let d = record.createdAt, !d.isEmpty { return d }
        return nil
    }

    /// Exact 0 is an unset sentinel — Null Island is not a vineyard.
    static func isValidLatitude(_ value: Double?) -> Bool {
        guard let value, value.isFinite else { return false }
        return value >= -90 && value <= 90 && value != 0
    }

    static func isValidLongitude(_ value: Double?) -> Bool {
        guard let value, value.isFinite else { return false }
        return value >= -180 && value <= 180 && value != 0
    }

    /// Canonical assignment (contract section 10). `pin_placements` can only
    /// ever **revoke** an assignment or confirm it; the block identity itself
    /// always comes from `paddock_id`.
    ///
    /// - Parameter explicitAssigned: the resolved placement signal, or `nil`
    ///   when the placement row carries no signal at all.
    static func resolveAssignment(explicitAssigned: Bool?, paddockId: String?) -> (assigned: Bool, paddockId: String?) {
        let hasBlock = !(paddockId ?? "").isEmpty
        let assigned: Bool
        if let explicitAssigned {
            assigned = explicitAssigned && hasBlock
        } else {
            assigned = hasBlock
        }
        return (assigned, assigned ? paddockId : nil)
    }

    /// Normalises raw records into heat observations, dropping everything the
    /// contract excludes. Order is preserved — IDW zero-distance hits resolve
    /// to the first matching observation in this order.
    static func toObservations(
        _ records: [RawRecord],
        assignedById: [String: Bool] = [:],
        selectedVineyardId: String? = nil
    ) -> [Observation] {
        var out: [Observation] = []
        out.reserveCapacity(records.count)
        for record in records {
            if isWrongVineyard(record, selectedVineyardId: selectedVineyardId) { continue }
            if let deleted = record.deletedAt, !deleted.isEmpty { continue }
            guard let el = parseElStage(record.stageCode) else { continue }
            guard isValidLatitude(record.latitude), isValidLongitude(record.longitude),
                  let lat = record.latitude, let lng = record.longitude else { continue }
            guard let dateISO = observationDate(record) else { continue }
            let resolved = resolveAssignment(
                explicitAssigned: assignedById[record.id],
                paddockId: record.paddockId
            )
            out.append(
                Observation(
                    id: record.id,
                    paddockId: resolved.paddockId,
                    assigned: resolved.assigned,
                    el: el,
                    lat: lat,
                    lng: lng,
                    dateISO: dateISO
                )
            )
        }
        return out
    }

    /// The reason a record was excluded, for diagnostics and contract tests.
    /// Evaluated in the same order as `toObservations`.
    static func isWrongVineyard(_ record: RawRecord, selectedVineyardId: String?) -> Bool {
        guard let selectedVineyardId, let owner = record.vineyardId else { return false }
        return owner != selectedVineyardId
    }

    static func exclusionReason(
        _ record: RawRecord,
        selectedVineyardId: String? = nil
    ) -> ExclusionReason? {
        // Scoping happens at the query boundary, so it precedes every other rule.
        if isWrongVineyard(record, selectedVineyardId: selectedVineyardId) { return .wrongVineyard }
        if let deleted = record.deletedAt, !deleted.isEmpty { return .deleted }
        if parseElStage(record.stageCode) == nil { return .elOutOfRangeOrUnparseable }
        if !isValidLatitude(record.latitude) || !isValidLongitude(record.longitude) {
            return .missingCoordinates
        }
        if observationDate(record) == nil { return .noObservationDate }
        return nil
    }

    // MARK: - Filtering and partitioning

    /// Inclusive day-key string comparison against the season range.
    static func filterToVintage(_ obs: [Observation], startISO: String, endISO: String) -> [Observation] {
        let s = dayKey(startISO)
        let e = dayKey(endISO)
        return obs.filter { o in
            let d = dayKey(o.dateISO)
            return d >= s && d <= e
        }
    }

    /// Observations that exist at the timeline date. Future observations are
    /// hidden completely — not stale, not counted, not rendered.
    static func qualifyingAt(_ obs: [Observation], dateISO: String) -> [Observation] {
        let d = dayKey(dateISO)
        return obs.filter { dayKey($0.dateISO) <= d }
    }

    static func isInfluencing(_ obs: Observation, atDateISO: String) -> Bool {
        let age = daysBetween(obs.dateISO, atDateISO)
        return age >= 0 && recencyWeight(ageDays: age) > 0
    }

    static func partitionByInfluence(
        _ obs: [Observation],
        atDateISO: String
    ) -> (influencing: [Observation], stale: [Observation]) {
        var influencing: [Observation] = []
        var stale: [Observation] = []
        for o in obs {
            if isInfluencing(o, atDateISO: atDateISO) { influencing.append(o) } else { stale.append(o) }
        }
        return (influencing, stale)
    }

    /// Ascending numeric median; the mean of the two middle values for an even
    /// count. Empty input is `nil`.
    static func medianStage(_ els: [Double]) -> Double? {
        if els.isEmpty { return nil }
        let v = els.sorted()
        let mid = v.count >> 1
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
    }

    static func medianStage(_ obs: [Observation]) -> Double? {
        medianStage(obs.map(\.el))
    }

    // MARK: - Geometry (contract section 8)

    nonisolated struct LatLng: Equatable, Sendable {
        let lat: Double
        let lng: Double

        init(lat: Double, lng: Double) {
            self.lat = lat
            self.lng = lng
        }
    }

    nonisolated struct Bounds: Equatable, Sendable {
        let minLat: Double
        let maxLat: Double
        let minLng: Double
        let maxLng: Double
    }

    /// Standard ray-casting / even-odd crossing test. Winding direction is
    /// irrelevant; the polygon is implicitly closed. Strict comparisons are
    /// reproduced exactly so edge behaviour matches the Portal.
    static func pointInPolygon(_ pt: LatLng, _ poly: [LatLng]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let yi = poly[i].lat, xi = poly[i].lng
            let yj = poly[j].lat, xj = poly[j].lng
            let denominator = (yj - yi) == 0 ? Double.ulpOfOne : (yj - yi)
            if (yi > pt.lat) != (yj > pt.lat),
               pt.lng < ((xj - xi) * (pt.lat - yi)) / denominator + xi {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    static func polygonBounds(_ poly: [LatLng]) -> Bounds? {
        guard !poly.isEmpty else { return nil }
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLng = Double.infinity, maxLng = -Double.infinity
        for p in poly {
            minLat = min(minLat, p.lat)
            maxLat = max(maxLat, p.lat)
            minLng = min(minLng, p.lng)
            maxLng = max(maxLng, p.lng)
        }
        return Bounds(minLat: minLat, maxLat: maxLat, minLng: minLng, maxLng: maxLng)
    }

    /// Bounding-box diagonal in cosine-corrected degrees. Note this uses the
    /// box's `minLat`, whereas per-cell distances use the *cell* latitude —
    /// both are reproduced exactly as the Portal writes them.
    static func boundsDiagonal(_ b: Bounds) -> Double {
        let dLat = b.maxLat - b.minLat
        let dLng = (b.maxLng - b.minLng) * cos(b.minLat * .pi / 180)
        return (dLat * dLat + dLng * dLng).squareRoot()
    }

    // MARK: - Modes (contract section 7)

    nonisolated enum Mode: String, Equatable, Sendable {
        case noPolygon = "no_polygon"
        case none
        case stale
        case halo
        case gradient
        case surface
    }

    /// `no_polygon` is evaluated first and wins over every other condition.
    static func blockHeatMode(influencing: Int, hasPolygon: Bool, totalObservations: Int) -> Mode {
        if !hasPolygon { return .noPolygon }
        if influencing <= 0 { return totalObservations > 0 ? .stale : .none }
        if influencing == 1 { return .halo }
        if influencing == 2 { return .gradient }
        return .surface
    }

    static func maxInfluence(mode: Mode, diagonal: Double) -> Double {
        switch mode {
        case .halo: return diagonal * haloFraction
        case .gradient: return diagonal * gradientFraction
        default: return .infinity
        }
    }

    // MARK: - IDW (contract section 5)

    nonisolated struct WeightedPoint: Equatable, Sendable {
        let lat: Double
        let lng: Double
        let el: Double
        let w: Double
    }

    nonisolated struct CellSample: Equatable, Sendable {
        let value: Double?
        let weight: Double?

        static let empty = CellSample(value: nil, weight: nil)
    }

    /// Evaluates one cell. Longitude is scaled by the cosine of the **cell**
    /// latitude; latitude deltas are unscaled. A zero-distance hit
    /// (`d² < 1e-14`) breaks immediately and takes that observation's exact
    /// value and recency weight, ignoring every later observation.
    static func evaluateCell(
        lat: Double,
        lng: Double,
        points: [WeightedPoint],
        maxInfluence: Double
    ) -> CellSample {
        var num = 0.0
        var den = 0.0
        var wNum = 0.0
        var nearest = Double.infinity
        var exact: (el: Double, w: Double)?

        for p in points {
            let dLat = lat - p.lat
            let dLng = (lng - p.lng) * cos(lat * .pi / 180)
            let d2 = dLat * dLat + dLng * dLng
            nearest = min(nearest, d2.squareRoot())
            if d2 < zeroDistanceEpsilonD2 {
                exact = (p.el, p.w)
                break
            }
            let wDist = 1 / pow(d2.squareRoot(), idwPower)
            let w = wDist * p.w
            num += p.el * w
            den += w
            wNum += p.w * wDist
        }

        if exact == nil && nearest > maxInfluence { return .empty }
        if let exact { return CellSample(value: exact.el, weight: exact.w) }
        guard den > 0 else { return .empty }

        let falloff = maxInfluence.isFinite ? clamp(1 - nearest / maxInfluence, 0, 1) : 1
        let cellW = clamp((wNum / (den == 0 ? 1 : den)) * falloff, 0, 1)
        return CellSample(value: num / den, weight: cellW)
    }

    // MARK: - Block and map models

    nonisolated struct BlockHeat: Sendable {
        let paddockId: String
        let paddockName: String?
        let polygon: [LatLng]
        let observations: [Observation]
        let influencing: [Observation]
        let stale: [Observation]
        let mode: Mode
        let medianEl: Double?
        let grid: [[Double?]]?
        let weightGrid: [[Double?]]?
        let gridBounds: Bounds?
        let diagonal: Double?
        let maxInfluenceDeg: Double?
        /// Influencing observations paired with their recency weight, in the
        /// order the IDW loop visits them.
        let points: [WeightedPoint]
    }

    nonisolated struct HeatModel: Sendable {
        let blocks: [BlockHeat]
        let unassigned: [Observation]
        let qualifying: [Observation]
        let influencing: [Observation]
        let stale: [Observation]
        let medianEl: Double?
    }

    static func buildBlockHeat(
        paddockId: String,
        paddockName: String?,
        polygon: [LatLng],
        observations: [Observation],
        atDateISO: String,
        resolution: Int = gridResolution
    ) -> BlockHeat {
        let hasPolygon = polygon.count >= 3
        let split = partitionByInfluence(observations, atDateISO: atDateISO)
        let mode = blockHeatMode(
            influencing: split.influencing.count,
            hasPolygon: hasPolygon,
            totalObservations: observations.count
        )
        let points = split.influencing.map { o in
            WeightedPoint(
                lat: o.lat,
                lng: o.lng,
                el: o.el,
                w: recencyWeight(ageDays: daysBetween(o.dateISO, atDateISO))
            )
        }
        let bounds = hasPolygon ? polygonBounds(polygon) : nil
        let diagonal = bounds.map(boundsDiagonal)

        // `none`, `stale` and `no_polygon` paint nothing at all.
        guard hasPolygon, !split.influencing.isEmpty, let b = bounds, let diag = diagonal else {
            return BlockHeat(
                paddockId: paddockId,
                paddockName: paddockName,
                polygon: polygon,
                observations: observations,
                influencing: split.influencing,
                stale: split.stale,
                mode: mode,
                medianEl: medianStage(split.influencing),
                grid: nil,
                weightGrid: nil,
                gridBounds: nil,
                diagonal: diagonal,
                maxInfluenceDeg: nil,
                points: points
            )
        }

        let influence = maxInfluence(mode: mode, diagonal: diag)
        let latStep = (b.maxLat - b.minLat) / Double(resolution - 1)
        let lngStep = (b.maxLng - b.minLng) / Double(resolution - 1)

        var grid: [[Double?]] = []
        var weightGrid: [[Double?]] = []
        grid.reserveCapacity(resolution)
        weightGrid.reserveCapacity(resolution)

        // Row 0 is the SOUTH edge; the rasteriser flips it when drawing.
        for i in 0..<resolution {
            let lat = b.minLat + latStep * Double(i)
            var rowVals: [Double?] = []
            var rowW: [Double?] = []
            rowVals.reserveCapacity(resolution)
            rowW.reserveCapacity(resolution)
            for j in 0..<resolution {
                let lng = b.minLng + lngStep * Double(j)
                guard pointInPolygon(LatLng(lat: lat, lng: lng), polygon) else {
                    rowVals.append(nil)
                    rowW.append(nil)
                    continue
                }
                let sample = evaluateCell(lat: lat, lng: lng, points: points, maxInfluence: influence)
                rowVals.append(sample.value)
                rowW.append(sample.weight)
            }
            grid.append(rowVals)
            weightGrid.append(rowW)
        }

        return BlockHeat(
            paddockId: paddockId,
            paddockName: paddockName,
            polygon: polygon,
            observations: observations,
            influencing: split.influencing,
            stale: split.stale,
            mode: mode,
            medianEl: medianStage(split.influencing),
            grid: grid,
            weightGrid: weightGrid,
            gridBounds: b,
            diagonal: diag,
            maxInfluenceDeg: influence.isFinite ? influence : nil,
            points: points
        )
    }

    nonisolated struct BlockInput: Sendable {
        let id: String
        let name: String?
        let polygon: [LatLng]

        init(id: String, name: String? = nil, polygon: [LatLng]) {
            self.id = id
            self.name = name
            self.polygon = polygon
        }
    }

    /// Builds the whole map model for one timeline date.
    ///
    /// Status counts follow contract section 9: *recorded observations
    /// available* counts every qualifying observation **including stale and
    /// unassigned ones**, while *influencing* and *stale* are both computed
    /// over assigned observations only. An unassigned pin therefore appears in
    /// the recorded total but in neither partition — the totals are not meant
    /// to balance.
    static func buildHeatModel(
        observations: [Observation],
        blocks: [BlockInput],
        atDateISO: String,
        blockFilter: String? = nil,
        resolution: Int = gridResolution
    ) -> HeatModel {
        let filter = (blockFilter == "all" || blockFilter?.isEmpty == true) ? nil : blockFilter
        let qualifyingAll = qualifyingAt(observations, dateISO: atDateISO)
        let qualifying = filter.map { f in qualifyingAll.filter { $0.paddockId == f } } ?? qualifyingAll

        var byBlock: [String: [Observation]] = [:]
        for o in qualifying {
            guard o.assigned, let pid = o.paddockId else { continue }
            byBlock[pid, default: []].append(o)
        }

        let wanted = filter.map { f in blocks.filter { $0.id == f } } ?? blocks
        let heat = wanted.map { b in
            buildBlockHeat(
                paddockId: b.id,
                paddockName: b.name,
                polygon: b.polygon,
                observations: byBlock[b.id] ?? [],
                atDateISO: atDateISO,
                resolution: resolution
            )
        }

        let assignedQualifying = qualifying.filter { $0.assigned && $0.paddockId != nil }
        let split = partitionByInfluence(assignedQualifying, atDateISO: atDateISO)

        return HeatModel(
            blocks: heat,
            unassigned: filter != nil ? [] : qualifying.filter { !$0.assigned || $0.paddockId == nil },
            qualifying: qualifying,
            influencing: split.influencing,
            stale: split.stale,
            medianEl: medianStage(split.influencing)
        )
    }
}

/// Timezone-free civil date used for whole-day arithmetic on ISO day keys.
/// Deliberately not `Foundation.Calendar`: the contract requires the stored
/// string's own date component to be treated as the vineyard-local day.
nonisolated struct CivilDate: Equatable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses a `YYYY-MM-DD` prefix. Returns `nil` for anything malformed.
    init?(dayKey: String) {
        let parts = dayKey.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              parts[0].count == 4, m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
        self.init(year: y, month: m, day: d)
    }

    var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Days from the Unix epoch (Howard Hinnant's civil algorithm).
    var epochDay: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func fromEpochDay(_ epochDay: Int) -> CivilDate {
        var z = epochDay + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        z -= era * 146097
        let yoe = (z - z / 1460 + z / 36524 - z / 146096) / 365
        let y = yoe + era * 400
        let doy = z - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return CivilDate(year: m <= 2 ? y + 1 : y, month: m, day: d)
    }

    func adding(days: Int) -> CivilDate {
        CivilDate.fromEpochDay(epochDay + days)
    }

    static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}
