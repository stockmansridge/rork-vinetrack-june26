import SwiftUI

/// Decorative tool identity, separate from map markers and semantic status colours.
struct BrightToolIcon: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 44

    /// The same palette as the existing Home operational tiles.
    static func operationalColors(for id: String, tint: Color) -> [Color] {
        switch id {
        case "work_tasks": return [.indigo, .purple]
        case "equipment_maintenance": return [VineyardTheme.earthBrown, .orange]
        case "fuel_log": return [.red, .orange]
        case "irrigation_advisor": return [.blue, .cyan]
        case "disease_risk": return [.green, .cyan]
        case "yield_records": return [.orange, .red]
        case "growth_stages": return [VineyardTheme.leafGreen, .cyan]
        case "optimal_ripeness": return [.pink, .orange]
        case "cost_reports": return [.green, .cyan]
        case "fertiliser_calculator": return [.cyan, VineyardTheme.leafGreen]
        case "pruning_tracker": return [.cyan, .indigo]
        case "irrigation_records": return [.cyan, .blue]
        case "resistance_planner": return [.purple, .pink]
        case "vineyard_insights": return [.purple, .indigo]
        default: return [tint, tint.opacity(0.75)]
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.27)
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
