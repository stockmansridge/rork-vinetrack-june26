import UIKit

/// Draws the map glyphs for observation pins and block labels.
///
/// Pins are deliberately small and high-contrast: they sit on top of a
/// saturated heat surface and a satellite basemap, so every style carries a
/// white outer ring to stay legible against both.
nonisolated enum ELRipenessPinFactory {

    static func uiColour(for el: Double, phase: ELRipeness.DevelopmentPhase? = nil) -> UIColor {
        let rgb = phase.map { ELRipeness.phaseColour(el, phase: $0) } ?? ELRipeness.elColour(el)
        return UIColor(
            red: CGFloat(rgb.r) / 255,
            green: CGFloat(rgb.g) / 255,
            blue: CGFloat(rgb.b) / 255,
            alpha: 1
        )
    }

    /// Observation pin.
    ///
    /// * `current` — solid E-L colour, the observation is driving the surface.
    /// * `stale` — hollow ring in the E-L colour, present but not influencing.
    /// * `unassigned` — amber ring with a hollow centre and a gap, signalling
    ///   the record has no block and is excluded from every block's maths.
    static func observationImage(
        el: Double,
        style: ELRipenessObservationAnnotation.Style,
        phase: ELRipeness.DevelopmentPhase? = nil
    ) -> UIImage {
        let diameter: CGFloat = style == .current ? 18 : 16
        let size = CGSize(width: diameter + 4, height: diameter + 4)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            let rect = CGRect(x: 2, y: 2, width: diameter, height: diameter)
            let colour = uiColour(for: el, phase: phase)

            switch style {
            case .current:
                cg.setFillColor(colour.cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(UIColor.white.cgColor)
                cg.setLineWidth(2)
                cg.strokeEllipse(in: rect)

            case .stale:
                cg.setFillColor(UIColor.black.withAlphaComponent(0.35).cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(colour.withAlphaComponent(0.9).cgColor)
                cg.setLineWidth(2.5)
                cg.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
                cg.setLineWidth(1)
                cg.strokeEllipse(in: rect)

            case .unassigned:
                cg.setFillColor(UIColor.black.withAlphaComponent(0.4).cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(UIColor.systemAmber.cgColor)
                cg.setLineWidth(2.5)
                cg.setLineDash(phase: 0, lengths: [3, 2.5])
                cg.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
                cg.setLineDash(phase: 0, lengths: [])
            }
        }
    }

    static func observationAccessibility(
        el: Double,
        style: ELRipenessObservationAnnotation.Style,
        blockName: String?,
        ageDays: Int
    ) -> String {
        let stage = ELRipeness.formatEl(el)
        let dayText = ageDays == 1 ? "1 day ago" : "\(ageDays) days ago"
        switch style {
        case .current:
            return "\(stage), \(blockName ?? "unknown block"), recorded \(dayText), influencing the surface"
        case .stale:
            return "\(stage), \(blockName ?? "unknown block"), recorded \(dayText), too old to influence the surface"
        case .unassigned:
            return "\(stage), no block assigned, recorded \(dayText), excluded from every block"
        }
    }

    /// Block name plus highest current recorded stage, drawn as a rounded plate.
    static func blockLabelImage(name: String, displayEl: Double?, mode: ELRipeness.Mode) -> UIImage {
        let title = name
        let detail = displayDetail(displayEl: displayEl, mode: mode)

        let titleFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let detailFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        let titleSize = (title as NSString).size(withAttributes: [.font: titleFont])
        let detailSize = (detail as NSString).size(withAttributes: [.font: detailFont])
        let width = max(titleSize.width, detailSize.width) + 16
        let height = titleSize.height + detailSize.height + 10
        let size = CGSize(width: ceil(width), height: ceil(height))

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            let plate = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: plate, cornerRadius: 6)
            cg.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
            cg.addPath(path.cgPath)
            cg.fillPath()

            (title as NSString).draw(
                at: CGPoint(x: (size.width - titleSize.width) / 2, y: 4),
                withAttributes: [.font: titleFont, .foregroundColor: UIColor.white]
            )
            let detailColour: UIColor = displayEl.map { uiColour(for: $0) } ?? UIColor.white.withAlphaComponent(0.7)
            (detail as NSString).draw(
                at: CGPoint(x: (size.width - detailSize.width) / 2, y: 4 + titleSize.height + 1),
                withAttributes: [.font: detailFont, .foregroundColor: detailColour]
            )
        }
    }

    /// Keep the existing no-data text when no current observation qualifies.
    static func displayDetail(displayEl: Double?, mode: ELRipeness.Mode) -> String {
        if let displayEl { return ELRipeness.formatEl(displayEl) }
        switch mode {
        case .stale: return "No current data"
        case .noPolygon: return "No boundary"
        default: return "—"
        }
    }

    static func blockLabelAccessibility(name: String, displayEl: Double?, mode: ELRipeness.Mode) -> String {
        if let displayEl {
            return "\(name), highest recorded \(ELRipeness.formatEl(displayEl)) from current observations"
        }
        switch mode {
        case .stale: return "\(name), no current observations"
        case .noPolygon: return "\(name), no block boundary recorded"
        default: return "\(name), no observations"
        }
    }
}

private extension UIColor {
    /// `systemAmber` does not exist on UIKit; this is the app's warning amber.
    static var systemAmber: UIColor {
        UIColor(red: 1.0, green: 0.72, blue: 0.16, alpha: 1.0)
    }
}
