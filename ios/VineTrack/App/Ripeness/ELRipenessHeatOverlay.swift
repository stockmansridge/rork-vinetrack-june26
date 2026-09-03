import CoreGraphics
import Foundation
import MapKit

/// One block's heat surface as a MapKit overlay.
///
/// Every block gets its own overlay with its own bitmap and its own clip path.
/// Nothing is shared between blocks, so cross-block colour influence is
/// structurally impossible rather than merely avoided: a block's raster only
/// ever contains cells that passed *its* polygon test, and the renderer then
/// clips to *its* polygon a second time.
nonisolated final class ELRipenessHeatOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let paddockId: String
    let image: CGImage
    let polygon: [CLLocationCoordinate2D]
    /// The rect the bitmap is drawn into — the grid bounds expanded by half a
    /// cell so pixel centres land exactly on contract grid nodes.
    let drawRect: MKMapRect

    var boundingMapRect: MKMapRect { drawRect }
    let coordinate: CLLocationCoordinate2D

    init(
        paddockId: String,
        image: CGImage,
        polygon: [CLLocationCoordinate2D],
        drawRect: MKMapRect
    ) {
        self.paddockId = paddockId
        self.image = image
        self.polygon = polygon
        self.drawRect = drawRect
        self.coordinate = MKMapPoint(x: drawRect.midX, y: drawRect.midY).coordinate
        super.init()
    }

    /// Builds the overlay for a block, or `nil` when the block paints nothing.
    ///
    /// The half-cell expansion matters: the contract samples grid *nodes* at
    /// `minLat + step * i`, so the outermost nodes sit exactly on the bounds.
    /// Drawing the bitmap edge-to-edge on those bounds would place pixel
    /// centres half a cell inboard and shift the whole surface. Expanding by
    /// half a cell re-aligns pixel centres with the sampled nodes.
    static func make(from block: ELRipeness.BlockHeat) -> ELRipenessHeatOverlay? {
        guard let bounds = block.gridBounds,
              let grid = block.grid,
              let resolution = grid.first?.count,
              resolution > 1,
              grid.count > 1,
              let image = ELRipenessHeatRaster.image(for: block) else { return nil }

        let latStep = (bounds.maxLat - bounds.minLat) / Double(grid.count - 1)
        let lngStep = (bounds.maxLng - bounds.minLng) / Double(resolution - 1)

        let north = bounds.maxLat + latStep / 2
        let south = bounds.minLat - latStep / 2
        let west = bounds.minLng - lngStep / 2
        let east = bounds.maxLng + lngStep / 2

        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: west))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: east))
        let rect = MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
        guard rect.width > 0, rect.height > 0 else { return nil }

        return ELRipenessHeatOverlay(
            paddockId: block.paddockId,
            image: image,
            polygon: block.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) },
            drawRect: rect
        )
    }
}

/// Draws a heat overlay, hard-clipped to its block polygon.
///
/// The clip is what guarantees the requirement that the surface never paints
/// outside its block. The bitmap is already transparent outside the polygon,
/// but it is drawn with interpolation so edge pixels would otherwise bleed a
/// fraction of a cell past the boundary.
nonisolated final class ELRipenessHeatOverlayRenderer: MKOverlayRenderer {

    private var heatOverlay: ELRipenessHeatOverlay? {
        overlay as? ELRipenessHeatOverlay
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let heatOverlay else { return }
        let rect = self.rect(for: heatOverlay.drawRect)
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }

        context.saveGState()

        if heatOverlay.polygon.count >= 3 {
            let path = CGMutablePath()
            for (index, coordinate) in heatOverlay.polygon.enumerated() {
                let point = self.point(for: MKMapPoint(coordinate))
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
            context.addPath(path)
            context.clip()
        }

        context.interpolationQuality = .high
        // MKOverlayRenderer hands us a flipped context; un-flip so the raster's
        // north-first row order draws the right way up.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(
            heatOverlay.image,
            in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        )

        context.restoreGState()
    }
}

/// The block boundary drawn above the heat surface.
nonisolated final class ELRipenessBlockOutline: MKPolygon {
    /// Set after construction because `MKPolygon`'s initialisers are not
    /// designated initialisers we can extend.
    var paddockId: String = ""
    var isSelected: Bool = false
}
