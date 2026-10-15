#if DEBUG
import SwiftUI

/// Visible, reproducible simulator model/IO samples. Does not authorize PerformanceCapture export.
struct SprayPerformanceValidationView: View {
    @State private var report: String = "Measuring synthetic model and durable IO…"
    var body: some View {
        ScrollView { Text(report).font(.system(.caption, design: .monospaced)).padding().accessibilityIdentifier("spray.performance.samples") }
            .task { report = Self.samples() }
    }

    @MainActor private static func samples() -> String {
        func measure(_ body: () throws -> Void) rethrows -> String {
            var samples: [Double] = []
            for _ in 0..<11 {
                let start = ProcessInfo.processInfo.systemUptime
                try body()
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            samples.sort()
            return String(format: "median=%.3fms max=%.3fms n=11", samples[5], samples[10])
        }
        var rows: [String] = ["SIMULATOR model / synchronous IO; not usable-frame or handset latency."]
        for (blocks, products) in [(5, 3), (100, 20)] {
            var inputs = SprayGuidedInputs()
            inputs.blocks = (0..<blocks).map { SprayBlockInput(blockId: "b\($0)", blockName: "Synthetic", grossAreaHectares: 1, rowSpacingMetres: 2.8) }
            inputs.carrierBasis = .manualTotalVolume
            inputs.manualTotalLitres = 1500
            inputs.tankCapacityLitres = 1500
            inputs.products = (0..<products).map { SprayProductLineInput(productId: "p\($0)", name: "Synthetic", unit: "L", basis: .wholeBlockArea, rate: 2) }
            let flow = SprayGuidedFlow(inputs: inputs)
            var checksumBefore: Double = 0
            var checksumAfter: Double = 0
            let before = measure {
                for _ in 0..<30 { for index in 0..<products { checksumBefore += flow.plan.productLines[index].totalQuantity ?? 0 } }
            }
            let after = measure {
                for _ in 0..<30 { let snapshot = flow.plan.productLines; for line in snapshot { checksumAfter += line.totalQuantity ?? 0 } }
            }
            rows.append("\(blocks) blocks / \(products) products / 30 loops per sample\nbefore \(before)\nafter \(after)\nequal=\(checksumBefore == checksumAfter)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calculator-timing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let repository = SprayRepository(persistence: PersistenceStore(directory: directory))
            let vineyard = UUID()
            for count in [5, 500] {
                let records = (0..<count).map { _ in SprayRecord(vineyardId: vineyard) }
                let save = try measure { try repository.saveRecordsSliceOrThrow(records, for: vineyard) }
                var loaded = 0
                let load = measure { loaded = repository.loadAllRecords().count }
                rows.append("\(count) synthetic recipes\ndurable save \(save)\nload \(load)\nloaded=\(loaded)")
            }
        } catch { rows.append("IO benchmark failed; no successful timing claimed") }
        return rows.joined(separator: "\n\n")
    }
}
#endif
