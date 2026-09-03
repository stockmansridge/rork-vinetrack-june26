import CoreGraphics
import Foundation

/// Turns one block's contract grid into an RGBA bitmap.
///
/// Kept free of MapKit so the pixel maths can be pinned by tests. Two
/// invariants matter more than anything else here:
///
/// 1. **The bitmap is transparent outside the block polygon.** A `nil` grid
///    cell — which is exactly what `buildBlockHeat` writes for every sample
///    point that failed the point-in-polygon test — becomes alpha 0. No block
///    can ever tint its neighbour, because a block's raster only ever contains
///    its own polygon's cells.
/// 2. **Only full-precision values are read.** Colour comes from the raw IDW
///    value and alpha from the raw cell weight. The six-decimal display copies
///    in the contract's expected file are never fed back in.
nonisolated enum ELRipenessHeatRaster {

    /// Bytes per pixel in the RGBA8 premultiplied buffer.
    static let bytesPerPixel = 4

    /// A raw pixel buffer plus the geometry needed to place it on a map.
    nonisolated struct Raster: Sendable, Equatable {
        let width: Int
        let height: Int
        /// RGBA8, premultiplied alpha, row 0 = **north**.
        let pixels: [UInt8]

        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let offset = (y * width + x) * ELRipenessHeatRaster.bytesPerPixel
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        }
    }

    /// Builds the pixel buffer for a block.
    ///
    /// The contract grid stores row 0 at the **south** edge; raster row 0 is the
    /// **north** edge, so rows are flipped here rather than at draw time.
    ///
    /// - Returns: `nil` when the block paints nothing at all (`none`, `stale`
    ///   and `no_polygon` modes, which carry no grid).
    static func raster(for block: ELRipeness.BlockHeat) -> Raster? {
        guard let grid = block.grid, let weights = block.weightGrid else { return nil }
        let height = grid.count
        guard height > 0, let width = grid.first?.count, width > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        var painted = false

        for row in 0..<height {
            // Flip: raster row 0 is north, grid row 0 is south.
            let gridRow = height - 1 - row
            let values = grid[gridRow]
            let weightRow = gridRow < weights.count ? weights[gridRow] : []

            for column in 0..<width {
                guard column < values.count, let value = values[column] else { continue }
                let weight = column < weightRow.count ? weightRow[column] : nil

                let alpha = ELRipeness.alpha255(value: value, cellWeight: weight)
                guard alpha > 0 else { continue }

                let colour = ELRipeness.elColour(value)
                let offset = (row * width + column) * bytesPerPixel
                let a = Double(alpha) / 255.0
                // Premultiplied: CoreGraphics needs the colour scaled by alpha.
                pixels[offset] = UInt8(clampByte(Double(colour.r) * a))
                pixels[offset + 1] = UInt8(clampByte(Double(colour.g) * a))
                pixels[offset + 2] = UInt8(clampByte(Double(colour.b) * a))
                pixels[offset + 3] = UInt8(clamping: alpha)
                painted = true
            }
        }

        guard painted else { return nil }
        return Raster(width: width, height: height, pixels: pixels)
    }

    private static func clampByte(_ value: Double) -> Int {
        Int(max(0, min(255, value.rounded())))
    }

    /// Wraps a raster in a `CGImage` for the overlay renderer.
    static func image(from raster: Raster) -> CGImage? {
        let bytesPerRow = raster.width * bytesPerPixel
        guard let provider = CGDataProvider(data: Data(raster.pixels) as CFData),
              let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: raster.width,
            height: raster.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colourSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func image(for block: ELRipeness.BlockHeat) -> CGImage? {
        guard let raster = raster(for: block) else { return nil }
        return image(from: raster)
    }
}
