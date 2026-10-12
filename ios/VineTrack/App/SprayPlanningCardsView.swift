import SwiftUI

/// Two inline decisions; the existing calculator continues to own canopy/products/review.
struct SprayPlanningCardsView: View {
    @Binding var configuration: SprayPassConfiguration?
    @Binding var method: SprayPlanningMethod
    @Binding var specification: SprayFullTankSpecification
    @Binding var tankText: String
    @Binding var areaText: String
    @Binding var rateText: String
    let region: RegionFormatter
    let resolution: SprayPlanningResolution?

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sprayer configuration").font(.headline)
                Picker("Sprayer configuration", selection: $configuration) {
                    ForEach(SprayPassConfiguration.allCases, id: \.self) { pass in
                        Text(pass.title).tag(Optional(pass))
                    }
                }.pickerStyle(.segmented)
                if let configuration {
                    SprayPassIllustration(configuration: configuration)
                    Text(configuration == .standardPass
                         ? "Two adjacent half-row faces: one complete-row equivalent per pass."
                         : "Both sides of two complete vine rows per pass.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Choose the configuration for this application. Historical configuration is not assumed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Physical vineyard row spacing stays unchanged. Controller travel and physical vine-row rates are different measures.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14).background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 12) {
                Text("Plan spray volume").font(.headline)
                Picker("Planning method", selection: $method) {
                    ForEach(SprayPlanningMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if method == .fullTank {
                    field("Intended tank volume (\(region.volumeUnitAbbreviation))", text: $tankText)
                    Picker("Specify full tank", selection: $specification) {
                        ForEach(SprayFullTankSpecification.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if specification == .targetArea {
                        field("Planned area (\(region.areaUnitAbbreviation))", text: $areaText)
                    } else {
                        field("Calibrated rate (\(region.volumePerAreaUnit))", text: $rateText)
                    }
                    Text("Planned area only. Actual block and row coverage is recorded during the Trip; no partial-block allocation is assumed.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Use selected block area and the spray-volume decision below.").font(.caption).foregroundStyle(.secondary)
                }
                if let resolution {
                    LabeledContent("Planned area", value: region.formatArea(hectares: resolution.plannedAreaHa))
                    LabeledContent("Intended water", value: region.formatVolume(litres: resolution.intendedLitres))
                    LabeledContent("Application rate", value: region.formatVolumePerArea(litresPerHectare: resolution.litresPerHectare))
                    if let physical = resolution.physicalRowLitresPer100m {
                        LabeledContent("Physical vine row", value: region.formatVolumePer100Length(physical))
                    }
                    if let travel = resolution.controllerLitresPer100mTravel {
                        LabeledContent("Controller travel", value: region.formatVolumePer100Length(travel))
                    }
                    Text("CF \(resolution.concentrationFactor, specifier: "%.2f")× — calculation only, not label approval.")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                } else if method == .fullTank {
                    Text("Confirm canopy and configuration; enter a positive volume and area/rate within the selected blocks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(SprayPlanningOperationalGate.migrationMessage).font(.caption).foregroundStyle(.secondary)
            }.padding(14).background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 14))
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            TextField(title, text: text).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
        }
    }
}

private struct SprayPassIllustration: View {
    let configuration: SprayPassConfiguration
    var body: some View {
        Canvas { context, size in
            let green = Color(red: 0.25, green: 0.46, blue: 0.22)
            let rows: [CGFloat] = configuration == .standardPass ? [0.18, 0.82] : [0.33, 0.67]
            for x in rows {
                let vine = CGRect(x: size.width * x - 9, y: 43, width: 18, height: 42)
                context.fill(Path(roundedRect: vine, cornerRadius: 7), with: .color(green.opacity(0.8)))
                context.stroke(Path { p in p.move(to: CGPoint(x: size.width * x, y: 76)); p.addLine(to: CGPoint(x: size.width * x, y: 96)) }, with: .color(.brown), lineWidth: 3)
            }
            let machine = CGRect(x: size.width * 0.5 - 16, y: 51, width: 32, height: 32)
            context.fill(Path(roundedRect: machine, cornerRadius: 6), with: .color(.secondary))
            if configuration == .overRow {
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: size.width * 0.23, y: 58)); p.addLine(to: CGPoint(x: size.width * 0.23, y: 24))
                    p.addLine(to: CGPoint(x: size.width * 0.77, y: 24)); p.addLine(to: CGPoint(x: size.width * 0.77, y: 58))
                }, with: .color(.secondary), lineWidth: 5)
            }
            let heads: [CGFloat] = configuration == .standardPass ? [0.42, 0.58] : [0.23, 0.43, 0.57, 0.77]
            for (index, x) in heads.enumerated() {
                let end: CGFloat = configuration == .standardPass ? (index == 0 ? 0.22 : 0.78) : (index < 2 ? 0.33 : 0.67)
                context.stroke(Path { p in p.move(to: CGPoint(x: size.width * x, y: 61)); p.addLine(to: CGPoint(x: size.width * end, y: 61)) }, with: .color(.cyan), style: StrokeStyle(lineWidth: 3, dash: [4, 3]))
                context.fill(Path(ellipseIn: CGRect(x: size.width * x - 4, y: 57, width: 8, height: 8)), with: .color(.cyan))
            }
        }.frame(height: 106).accessibilityLabel(configuration == .standardPass ? "Standard sprayer between two rows, treating the adjacent half faces" : "Over-row boom with four spray heads treating both sides of two rows")
    }
}
