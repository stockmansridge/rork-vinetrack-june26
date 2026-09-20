import SwiftUI
import UIKit
import CoreLocation

extension VineyardTheme {
    static let uiOlive = UIColor(red: 0.45, green: 0.50, blue: 0.25, alpha: 1.0)
    static let uiLeafGreen = UIColor(red: 0.36, green: 0.55, blue: 0.30, alpha: 1.0)
}

enum PDFHeaderHelper {
    static func drawHeader(
        vineyardName: String,
        logoData: Data?,
        title: String,
        accentColor: UIColor,
        margin: CGFloat,
        contentWidth: CGFloat,
        y: inout CGFloat
    ) {
        let titleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
        let subtitleFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let logoSize: CGFloat = 48

        var textOriginX = margin
        if let logoData, let logo = UIImage(data: logoData), logo.size.width > 0, logo.size.height > 0 {
            let scale = min(logoSize / logo.size.width, logoSize / logo.size.height)
            let size = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
            let rect = CGRect(x: margin, y: y + (logoSize - size.height) / 2, width: size.width, height: size.height)
            logo.draw(in: rect)
            textOriginX = margin + logoSize + 12
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: accentColor,
        ]
        title.draw(at: CGPoint(x: textOriginX, y: y), withAttributes: titleAttrs)

        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: subtitleFont,
            .foregroundColor: UIColor.darkGray,
        ]
        vineyardName.draw(at: CGPoint(x: textOriginX, y: y + 26), withAttributes: subtitleAttrs)

        y += max(logoSize, 50) + 8
        let lineRect = CGRect(x: margin, y: y, width: contentWidth, height: 1)
        accentColor.setFill()
        UIRectFill(lineRect)
        y += 12
    }
}

extension Color {
    static func fromString(_ name: String) -> Color {
        let token = PinColorTokenContract.normalized(name) ?? "gray"
        let rgb = PinColorTokenContract.hexByToken[token] ?? 0x8E8E93
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

extension Array where Element == CoordinatePoint {
    var centroid: CLLocationCoordinate2D {
        guard !isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        let lat = map(\.latitude).reduce(0, +) / Double(count)
        let lon = map(\.longitude).reduce(0, +) / Double(count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
