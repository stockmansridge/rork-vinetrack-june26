//
//  Item.swift
//  VineTrack
//
//  Created by Rork on April 27, 2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}
    var timestamp: Date

    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
