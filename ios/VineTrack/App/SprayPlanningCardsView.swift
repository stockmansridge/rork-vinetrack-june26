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
    var rateUnit: String? = nil
    var rowSpacingMetres: Double? = nil
    let resolution: SprayPlanningResolution?
    var showsFullTankOption: Bool = true

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Text("Sprayer pass setup").font(.headline)
                    SprayFieldHelp(title: "Optional pass setup",
                        message: "Single Row covers the facing sides of two adjacent vine rows. 2 Row covers both sides of two complete vine rows from an aisle pass. Leaving it unset retains normal Tank Mixing and Trip. These choices do not select a true over-row machine route.")
                }
                Text(configuration == nil ? "Normal Tank Mixing → Trip" : "\(configuration!.title) pass selected")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Sprayer configuration", selection: $configuration) {
                    Text("Not Set").tag(SprayPassConfiguration?.none)
                    ForEach(SprayPassConfiguration.allCases, id: \.self) { pass in
                        Text(pass.title).tag(Optional(pass))
                    }
                }.pickerStyle(.segmented).accessibilityIdentifier("spray.passConfiguration")
                if let configuration {
                    SprayPassIllustration(configuration: configuration)
                    Text(configuration == .standardPass ? "1 row equivalent per pass" : "2 row equivalents per pass")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let rowSpacingMetres {
                    LabeledContent("Vineyard row spacing", value: region.formatLength(metres: rowSpacingMetres))
                }
                if let width = resolution?.effectiveWorkingWidthMetres {
                    LabeledContent("Effective working width", value: region.formatLength(metres: width))
                }
                if let travel = resolution?.controllerLitresPer100mTravel {
                    LabeledContent("Controller application", value: region.formatVolumePer100Length(travel))
                }
                SprayFieldHelp(title: "Controller rates",
                    message: "Physical vineyard row spacing stays unchanged. Controller travel, row equivalents and actual vine-row spray rates are different measures. VineTrack calculates the controller figure using the selected setup.")
            }.padding(14).background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Text("Plan spray volume").font(.headline)
                    SprayFieldHelp(title: "Water planning", message: "By Area calculates carrier water from selected blocks. Only Full Tanks is a legacy planning option that cannot currently start a spray and should not be selected for a new One-off application.")
                }
                if showsFullTankOption {
                    Picker("Planning method", selection: $method) {
                        ForEach(SprayPlanningMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                } else {
                    Text("By Area · selected blocks")
                        .font(.subheadline.weight(.medium))
                }
                if method == .fullTank {
                    field("Intended tank volume (\(region.volumeUnitAbbreviation))", text: $tankText, id: "spray.planning.tank")
                    Picker("Specify Only Full Tanks", selection: $specification) {
                        ForEach(SprayFullTankSpecification.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if specification == .targetArea {
                        field("Planned area (\(region.areaUnitAbbreviation))", text: $areaText, id: "spray.planning.area")
                    } else {
                        field("Calibrated rate (\(rateUnit ?? region.volumePerAreaUnit))", text: $rateText, id: "spray.planning.rate")
                    }
                    SprayFieldHelp(title: "Full Tank planning",
                        message: "Planned area is not proof of actual treated rows or blocks. True coverage is recorded during the Trip. This legacy planning mode cannot currently start a spray.")
                } else {
                    Text("Calculate the spray using the selected block area.").font(.caption).foregroundStyle(.secondary)
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
                if method == .fullTank {
                    Text(LegacySpraySetup.fullTankMessage).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14).background(Color(.secondarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 14))
        }
    }

    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            TextField(title, text: text).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).accessibilityIdentifier(id)
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
                let row: CGFloat = configuration == .standardPass ? (index == 0 ? 0.18 : 0.82) : (index < 2 ? 0.33 : 0.67)
                let direction: CGFloat = row > x ? 1 : -1
                let tip = size.width * row - direction * 13
                context.stroke(Path { p in p.move(to: CGPoint(x: size.width * x, y: 61)); p.addLine(to: CGPoint(x: tip - direction * 7, y: 61)) }, with: .color(.cyan), style: StrokeStyle(lineWidth: 3, dash: [4, 3]))
                context.fill(Path { p in
                    p.move(to: CGPoint(x: tip, y: 61))
                    p.addLine(to: CGPoint(x: tip - direction * 8, y: 56))
                    p.addLine(to: CGPoint(x: tip - direction * 8, y: 66))
                    p.closeSubpath()
                }, with: .color(.cyan))
            }
        }.frame(height: 106).accessibilityLabel(configuration == .standardPass ? "Single Row sprayer, arrows pointing left and right toward adjacent vine-row faces" : "Two Row aisle sprayer with four heads treating both sides of two adjacent vine rows")
    }
}
