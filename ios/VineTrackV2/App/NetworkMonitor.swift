//
//  NetworkMonitor.swift
//  VineTrackV2
//
//  Network reachability observer used to drive the offline map fallback.
//  Field navigation must never depend on cellular coverage, so views observe
//  `isOnline` to decide whether to render Apple hybrid/satellite tiles or the
//  overlay-only vineyard map.
//

import Foundation
import Network
import Observation

/// Observable wrapper around `NWPathMonitor`. Reports a coarse `isOnline`
/// flag plus whether the path is constrained/expensive, so map views can fall
/// back to the offline overlay renderer when tiles cannot load.
@Observable
final class NetworkMonitor {
    /// Shared instance. Injected into the SwiftUI environment at app launch.
    static let shared = NetworkMonitor()

    /// True when the device reports a satisfied network path.
    private(set) var isOnline: Bool = true
    /// True when the path is marked expensive (cellular / hotspot).
    private(set) var isExpensive: Bool = false
    /// True when the path is constrained (Low Data Mode).
    private(set) var isConstrained: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.vinetrack.networkmonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            // Hop back to the main actor so SwiftUI observation fires on the
            // correct thread.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isOnline != online {
                    print("[NetworkMonitor] connectivity changed -> \(online ? "online" : "offline")")
                }
                self.isOnline = online
                self.isExpensive = expensive
                self.isConstrained = constrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
