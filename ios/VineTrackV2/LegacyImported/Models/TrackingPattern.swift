import Foundation

nonisolated enum TrackingPattern: String, Codable, Sendable, CaseIterable, Identifiable {
    case sequential = "sequential"
    case everySecondRow = "everySecondRow"
    case fiveThree = "fiveThree"
    case upAndBack = "upAndBack"
    case twoRowUpBack = "twoRowUpBack"
    case custom = "custom"
    /// Free Drive — operator is not following a planned row sequence.
    /// No sequence generated; rows are detected and ticked off live based
    /// on the tractor's actual GPS position relative to row geometry.
    case freeDrive = "freeDrive"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequential: return "One After Another"
        case .everySecondRow: return "Every Second Row"
        case .fiveThree: return "3/5 Pattern"
        case .upAndBack: return "Up and Back"
        case .twoRowUpBack: return "2 Row Up & Back"
        case .custom: return "Custom"
        case .freeDrive: return "Free Drive"
        }
    }

    var subtitle: String {
        switch self {
        case .sequential: return "0.5, 1.5, 2.5 ... lastRow+0.5"
        case .everySecondRow: return "0.5, 2.5, 4.5 ... then 3.5, 1.5"
        case .fiveThree: return "0.5, 3.5, 1.5, 5.5, 2.5 ... +5, -3"
        case .upAndBack: return "0.5, 0.5, 1.5, 1.5 ... each path twice"
        case .twoRowUpBack: return "Spray 2, Skip 2 up then back"
        case .custom: return "Save & reuse your own sequences"
        case .freeDrive: return "No planned path — detect rows live"
        }
    }

    var icon: String {
        switch self {
        case .sequential: return "arrow.right"
        case .everySecondRow: return "arrow.right.arrow.left"
        case .fiveThree: return "arrow.triangle.swap"
        case .upAndBack: return "arrow.up.arrow.down"
        case .twoRowUpBack: return "arrow.up.and.down.text.horizontal"
        case .custom: return "slider.horizontal.3"
        case .freeDrive: return "scribble.variable"
        }
    }

    func generateSequence(startRow: Int, totalRows: Int, reversed: Bool = false) -> [Double] {
        // Free Drive intentionally has no planned sequence.
        if self == .freeDrive { return [] }
        guard totalRows > 0 else { return [] }

        let firstPath = Double(startRow) - 0.5
        let totalPaths = totalRows + 1

        var result: [Double]

        switch self {
        case .sequential:
            result = (0..<totalPaths).map { firstPath + Double($0) }

        case .everySecondRow:
            var sequence: [Double] = []
            for i in stride(from: 0, to: totalPaths, by: 2) {
                sequence.append(firstPath + Double(i))
            }
            for i in stride(from: totalPaths - 1, through: 0, by: -2) {
                let path = firstPath + Double(i)
                if !sequence.contains(path) {
                    sequence.append(path)
                }
            }
            for i in 0..<totalPaths {
                let path = firstPath + Double(i)
                if !sequence.contains(path) {
                    sequence.append(path)
                }
            }
            result = sequence

        case .upAndBack:
            var sequence: [Double] = []
            for i in 0..<totalPaths {
                let path = firstPath + Double(i)
                sequence.append(path)
                sequence.append(path)
            }
            result = sequence

        case .fiveThree:
            result = Self.generateFiveThreeSequence(firstPath: firstPath, totalPaths: totalPaths)

        case .twoRowUpBack:
            result = Self.generateTwoRowUpBackSequence(firstPath: firstPath, totalPaths: totalPaths)

        case .custom:
            result = (0..<totalPaths).map { firstPath + Double($0) }

        case .freeDrive:
            result = []
        }

        if reversed {
            result.reverse()
        }
        return result
    }

    private static func generateTwoRowUpBackSequence(firstPath: Double, totalPaths: Int) -> [Double] {
        let lastPath = firstPath + Double(totalPaths - 1)

        var upPaths: [Double] = []
        var path = firstPath + 1.0
        while path <= lastPath {
            upPaths.append(path)
            path += 4.0
        }

        var backPaths: [Double] = []
        path = firstPath + 3.0
        while path <= lastPath {
            backPaths.append(path)
            path += 4.0
        }
        backPaths.reverse()

        var result = upPaths + backPaths

        let visited = Set(result)
        var remaining: [Double] = []
        var r = firstPath
        while r <= lastPath {
            if !visited.contains(r) {
                remaining.append(r)
            }
            r += 1.0
        }
        result.append(contentsOf: remaining)

        return result
    }

    private static func generateFiveThreeSequence(firstPath: Double, totalPaths: Int) -> [Double] {
        let startRow = firstPath
        let endRow = firstPath + Double(totalPaths - 1)
        let startupPattern: [Double] = [0, 3, 1, 5, 2].map { startRow + $0 }

        var result: [Double] = []
        var visited = Set<Double>()

        for row in startupPattern {
            if row >= startRow && row <= endRow && !visited.contains(row) {
                result.append(row)
                visited.insert(row)
            }
        }

        guard var current = result.last else {
            return (0..<totalPaths).map { firstPath + Double($0) }
        }

        var usePlusFive = true

        while true {
            let next = usePlusFive ? current + 5.0 : current - 3.0

            if next < startRow || next > endRow || visited.contains(next) {
                break
            }

            result.append(next)
            visited.insert(next)
            current = next
            usePlusFive.toggle()
        }

        var allRows: [Double] = []
        var row = startRow
        while row <= endRow {
            allRows.append(row)
            row += 1.0
        }

        let remaining = allRows.filter { !visited.contains($0) }

        if !remaining.isEmpty {
            result.append(contentsOf: remaining)
        }

        return result
    }
}
