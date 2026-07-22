import Foundation

nonisolated enum DiseaseModel: String, Sendable, CaseIterable {
    case downyMildew = "downy_mildew"
    case powderyMildew = "powdery_mildew"
    case botrytis = "botrytis"

    var displayName: String {
        switch self {
        case .downyMildew: return "Downy mildew"
        case .powderyMildew: return "Powdery mildew"
        case .botrytis: return "Botrytis"
        }
    }
}

nonisolated struct DiseaseRiskAssessment: Sendable, Hashable {
    let model: DiseaseModel
    /// `nil` means no actionable risk.
    let severity: AlertSeverity?
    let title: String
    let summary: String
    /// True when at least one hour used a measured leaf wetness reading
    /// from an ag-weather provider rather than the proxy.
    let usedMeasuredWetness: Bool
}

/// Disease pressure models. The wetness signal is an *estimated proxy*
/// (rain > 0 OR RH >= 90% OR (T - dewPoint) <= 2°C) unless measured leaf
/// wetness is supplied on `WeatherHour`. Models are intentionally
/// simplified versions of well-known viticulture rules so they remain
/// useful with widely-available forecast data.
nonisolated enum DiseaseRiskCalculator {
    static func assess(
        hours: [WeatherHour],
        models: Set<DiseaseModel> = Set(DiseaseModel.allCases),
        now: Date = Date()
    ) -> [DiseaseRiskAssessment] {
        guard !hours.isEmpty else { return [] }
        var out: [DiseaseRiskAssessment] = []
        if models.contains(.downyMildew) {
            out.append(downyMildew(hours: hours, now: now))
        }
        if models.contains(.powderyMildew) {
            out.append(powderyMildew(hours: hours, now: now))
        }
        if models.contains(.botrytis) {
            out.append(botrytis(hours: hours, now: now))
        }
        return out
    }

    // MARK: - Downy mildew (simplified 10:10:24 rule)
    /// Risk when the past 24–48h shows >=10mm rain, min temp >=10°C and
    /// >=10 wet hours (estimated unless measured override exists).
    static func downyMildew(hours: [WeatherHour], now: Date = Date()) -> DiseaseRiskAssessment {
        let window = hours.filter {
            $0.date <= now && $0.date >= now.addingTimeInterval(-48 * 3600)
        }
        guard !window.isEmpty else {
            return DiseaseRiskAssessment(
                model: .downyMildew,
                severity: nil,
                title: "Downy mildew",
                summary: "Insufficient hourly data to assess.",
                usedMeasuredWetness: false
            )
        }
        let rain = window.map(\.precipitationMm).reduce(0, +)
        let minTemp = window.map(\.temperatureC).min() ?? 0
        let wetHours = window.filter { $0.isWetHour }.count
        let measured = window.contains { $0.isWetnessMeasured }

        var severity: AlertSeverity? = nil
        if rain >= 10 && minTemp >= 10 && wetHours >= 10 {
            severity = .warning
            if rain >= 20 && wetHours >= 18 { severity = .critical }
        }

        let wetnessLabel = measured ? "wet hours" : "estimated wet hours"
        let summary = String(
            format: "Past 48h: %.1f mm rain, min %.1f°C, %d %@.",
            rain, minTemp, wetHours, wetnessLabel
        )
        return DiseaseRiskAssessment(
            model: .downyMildew,
            severity: severity,
            title: "Downy mildew risk",
            summary: summary,
            usedMeasuredWetness: measured
        )
    }

    // MARK: - Powdery mildew (simplified Gubler-Thomas style)
    /// Counts consecutive hours in the past 72h with temperature 21–30°C
    /// and RH >= 60%. >=6 consecutive favourable hours over multiple days
    /// pushes the index up.
    static func powderyMildew(hours: [WeatherHour], now: Date = Date()) -> DiseaseRiskAssessment {
        let window = hours.filter {
            $0.date <= now && $0.date >= now.addingTimeInterval(-72 * 3600)
        }
        guard !window.isEmpty else {
            return DiseaseRiskAssessment(
                model: .powderyMildew,
                severity: nil,
                title: "Powdery mildew",
                summary: "Insufficient hourly data to assess.",
                usedMeasuredWetness: false
            )
        }

        var favourableDays = 0
        // Group by calendar day, count days with >=6 consecutive favourable hours.
        let cal = Calendar.current
        let byDay = Dictionary(grouping: window) { cal.startOfDay(for: $0.date) }
        for (_, dayHours) in byDay {
            let sorted = dayHours.sorted { $0.date < $1.date }
            var run = 0
            var maxRun = 0
            for h in sorted {
                let humidOK = (h.humidityPercent ?? 0) >= 60
                let tempOK = h.temperatureC >= 21 && h.temperatureC <= 30
                if humidOK && tempOK {
                    run += 1
                    maxRun = max(maxRun, run)
                } else {
                    run = 0
                }
            }
            if maxRun >= 6 { favourableDays += 1 }
        }

        var severity: AlertSeverity? = nil
        if favourableDays >= 3 { severity = .warning }
        if favourableDays >= 3 && (window.last?.temperatureC ?? 0) >= 25 {
            // Sustained mid-summer pressure
            severity = .critical
        }

        let summary = "\(favourableDays) of last 3 days had 6+ favourable hours (21–30°C, RH ≥ 60%)."
        return DiseaseRiskAssessment(
            model: .powderyMildew,
            severity: severity,
            title: "Powdery mildew risk",
            summary: summary,
            usedMeasuredWetness: false
        )
    }

    // MARK: - Botrytis (Broome/Bulit style simplified)
    /// Risk when the past 36h has wet hours combined with temperatures
    /// in the 15–25°C window. >=15 wet hours within range = warning.
    static func botrytis(hours: [WeatherHour], now: Date = Date()) -> DiseaseRiskAssessment {
        let window = hours.filter {
            $0.date <= now && $0.date >= now.addingTimeInterval(-36 * 3600)
        }
        guard !window.isEmpty else {
            return DiseaseRiskAssessment(
                model: .botrytis,
                severity: nil,
                title: "Botrytis",
                summary: "Insufficient hourly data to assess.",
                usedMeasuredWetness: false
            )
        }
        let measured = window.contains { $0.isWetnessMeasured }
        let qualifying = window.filter {
            $0.isWetHour && $0.temperatureC >= 15 && $0.temperatureC <= 25
        }
        let wetCount = qualifying.count

        var severity: AlertSeverity? = nil
        if wetCount >= 15 { severity = .warning }
        if wetCount >= 24 { severity = .critical }

        let label = measured ? "wet hours" : "estimated wet hours"
        let summary = String(
            format: "%d %@ in 15–25°C window over past 36h.",
            wetCount, label
        )
        return DiseaseRiskAssessment(
            model: .botrytis,
            severity: severity,
            title: "Botrytis risk",
            summary: summary,
            usedMeasuredWetness: measured
        )
    }
}
