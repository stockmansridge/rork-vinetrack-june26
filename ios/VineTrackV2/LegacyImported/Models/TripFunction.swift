import Foundation

/// Preset list of vineyard/maintenance operations the operator can pick from
/// when starting a trip. The raw value is the persisted string (kept stable
/// for backend storage / reporting) and `displayName` is the user-facing label.
nonisolated enum TripFunction: String, CaseIterable, Codable, Sendable, Identifiable {
    case slashing
    case mulching
    case harrowing
    case mowing
    case spraying
    case fertilising
    case undervineWeeding
    // Undervine weeding method subtypes. Stored as stable raw values so the
    // portal can report on each as a separate operation type.
    case undervineMowing
    case undervineMulticlean
    case undervineRollHacke
    case undervineDisc
    case undervineKnifing
    case interRowCultivation
    case pruning
    case shootThinning
    case canopyWork
    case irrigationCheck
    case repairs
    case seeding
    case spreading
    case other

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .slashing:           return "Slashing"
        case .mulching:           return "Mulching"
        case .harrowing:          return "Harrowing"
        case .mowing:             return "Mowing"
        case .spraying:           return "Spraying"
        case .fertilising:        return "Fertilising"
        case .undervineWeeding:   return "Undervine weeding"
        case .undervineMowing:    return "Mowing"
        case .undervineMulticlean:return "Multiclean"
        case .undervineRollHacke: return "Roll Hacke"
        case .undervineDisc:      return "Undervine Disc"
        case .undervineKnifing:   return "Undervine Knifing"
        case .interRowCultivation:return "Inter-row cultivation"
        case .pruning:            return "Pruning"
        case .shootThinning:      return "Shoot thinning"
        case .canopyWork:         return "Canopy work"
        case .irrigationCheck:    return "Irrigation check"
        case .repairs:            return "Repairs"
        case .seeding:            return "Seeding"
        case .spreading:          return "Spreading"
        case .other:              return "Other"
        }
    }

    /// Undervine weeding method subtypes, grouped under "Undervine weeding"
    /// in the trip function picker.
    nonisolated static let undervineWeedingSubtypes: [TripFunction] = [
        .undervineMowing,
        .undervineMulticlean,
        .undervineRollHacke,
        .undervineDisc,
        .undervineKnifing
    ]

    nonisolated var isUndervineWeedingSubtype: Bool {
        TripFunction.undervineWeedingSubtypes.contains(self)
    }

    nonisolated var icon: String {
        switch self {
        case .slashing:           return "scissors"
        case .mulching:           return "leaf.fill"
        case .harrowing:          return "rectangle.grid.3x2"
        case .mowing:             return "scissors.badge.ellipsis"
        case .spraying:           return "sprinkler.and.droplets.fill"
        case .fertilising:        return "drop.fill"
        case .undervineWeeding:   return "leaf"
        case .undervineMowing:    return "scissors.badge.ellipsis"
        case .undervineMulticlean:return "sparkles"
        case .undervineRollHacke: return "circle.grid.cross"
        case .undervineDisc:      return "circle.circle"
        case .undervineKnifing:   return "line.diagonal"
        case .interRowCultivation:return "square.grid.3x3"
        case .pruning:            return "scissors.circle"
        case .shootThinning:      return "leaf.arrow.triangle.circlepath"
        case .canopyWork:         return "tree.fill"
        case .irrigationCheck:    return "drop.circle"
        case .repairs:            return "wrench.and.screwdriver.fill"
        case .seeding:            return "leaf.circle.fill"
        case .spreading:          return "square.grid.3x3.fill"
        case .other:              return "ellipsis.circle"
        }
    }
}
