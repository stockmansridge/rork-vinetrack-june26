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
        if let logoData, let logo = UIImage(data: logoData) {
            let rect = CGRect(x: margin, y: y, width: logoSize, height: logoSize)
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
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "darkgreen": return Color(red: 0.10, green: 0.45, blue: 0.20)
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        case "black": return .black
        case "white": return .white
        default: return VineyardTheme.olive
        }
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
