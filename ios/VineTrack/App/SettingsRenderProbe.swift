import Foundation

/// Measurements are inert in release; no observable publications from the probe.
@MainActor enum SettingsRenderProbe {
    #if DEBUG
    static var rootBodies = 0
    static var imageConstructions = 0
    static func reset() { rootBodies = 0; imageConstructions = 0 }
    #endif
}
