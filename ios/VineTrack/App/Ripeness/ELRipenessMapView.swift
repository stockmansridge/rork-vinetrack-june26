import MapKit
import SwiftUI

/// An observation pin on the heat map.
nonisolated final class ELRipenessObservationAnnotation: NSObject, MKAnnotation, @unchecked Sendable {
    nonisolated enum Style: Equatable, Sendable {
        /// Inside the 84-day influence window — contributes to the surface.
        case current
        /// Recorded, still visible, but no longer influencing.
        case stale
        /// No block assignment, so it is shown but excluded from every block.
        case unassigned
    }

    let observation: ELRipeness.Observation
    let style: Style
    let blockName: String?
    let ageDays: Int
    let recencyWeight: Double
    let coordinate: CLLocationCoordinate2D

    var title: String? { ELRipeness.formatEl(observation.el) }
    var subtitle: String? { blockName }

    init(
        observation: ELRipeness.Observation,
        style: Style,
        blockName: String?,
        ageDays: Int,
        recencyWeight: Double
    ) {
        self.observation = observation
        self.style = style
        self.blockName = blockName
        self.ageDays = ageDays
        self.recencyWeight = recencyWeight
        self.coordinate = CLLocationCoordinate2D(latitude: observation.lat, longitude: observation.lng)
        super.init()
    }
}

/// A block's name and influencing-only median, floated at its centroid.
nonisolated final class ELRipenessBlockLabelAnnotation: NSObject, MKAnnotation, @unchecked Sendable {
    let paddockId: String
    let name: String
    /// Median of the **influencing** observations only. Stale observations are
    /// visible on the map but must not move this number.
    let medianEl: Double?
    let mode: ELRipeness.Mode
    let coordinate: CLLocationCoordinate2D

    init(paddockId: String, name: String, medianEl: Double?, mode: ELRipeness.Mode, coordinate: CLLocationCoordinate2D) {
        self.paddockId = paddockId
        self.name = name
        self.medianEl = medianEl
        self.mode = mode
        self.coordinate = coordinate
        super.init()
    }
}

/// MapKit host for the ripeness surface.
///
/// Uses `MKMapView` directly rather than SwiftUI `Map` because the heat surface
/// needs a custom `MKOverlayRenderer` — a per-block bitmap clipped to the block
/// polygon — which SwiftUI's map has no equivalent for.
struct ELRipenessMapView: UIViewRepresentable {
    let overlays: [ELRipenessHeatOverlay]
    let blocks: [ELRipeness.BlockHeat]
    /// Every block in the vineyard, from the cached paddock polygons — the
    /// same source the vineyard/pins map draws from.
    ///
    /// Framing and outlines are driven by this rather than by `blocks`: the
    /// heat model resolves asynchronously, so framing off it left the camera
    /// at MapKit's default world position on first paint. It also means blocks
    /// with no observations are still outlined and still count towards the fit.
    let allBlocks: [ELRipeness.BlockInput]
    let annotations: [ELRipenessObservationAnnotation]
    let labels: [ELRipenessBlockLabelAnnotation]
    let selectedBlockId: String?
    /// Basemap tiles need a network. Offline we drop to a plain background and
    /// keep drawing polygons, pins and heat from cache.
    let isOnline: Bool
    let onSelectObservation: (ELRipeness.Observation) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.accessibilityLabel = "Ripeness heat map"
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.mapType = isOnline ? .hybrid : .mutedStandard
        if !isOnline {
            mapView.backgroundColor = UIColor.secondarySystemBackground
        }
        context.coordinator.onSelectObservation = onSelectObservation

        // Overlay cleanup: heat surfaces are rebuilt wholesale on every date
        // change, so stale bitmaps are removed rather than accumulated.
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })

        // Outline every active block, including those with no observations,
        // so the operator sees the whole vineyard rather than only the parts
        // that happen to carry data.
        for block in allBlocks where block.polygon.count >= 3 {
            var coords = block.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
            let outline = ELRipenessBlockOutline(coordinates: &coords, count: coords.count)
            outline.paddockId = block.id
            outline.isSelected = block.id == selectedBlockId
            mapView.addOverlay(outline, level: .aboveRoads)
        }
        for overlay in overlays {
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        mapView.addAnnotations(labels)
        mapView.addAnnotations(annotations)

        let focusKey = "\(selectedBlockId ?? "all")-\(allBlocks.map(\.id).joined(separator: ","))"
        if context.coordinator.focusKey != focusKey {
            context.coordinator.focusKey = focusKey
            focus(mapView)
        }
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        // Break the delegate cycle and drop bitmaps promptly.
        mapView.delegate = nil
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
    }

    /// Frames the selected block, or the whole vineyard for "All Blocks".
    ///
    /// Falls back to observation pins only when no polygon exists at all. If
    /// even that is empty the camera is left alone rather than pointed at
    /// MapKit's country-wide default; the screen shows a missing-boundaries
    /// notice instead.
    private func focus(_ mapView: MKMapView) {
        let framing = allBlocks.filter { block in
            guard block.polygon.count >= 3 else { return false }
            guard let selectedBlockId else { return true }
            return block.id == selectedBlockId
        }

        var rect = MKMapRect.null
        for block in framing {
            for point in block.polygon {
                let mapPoint = MKMapPoint(CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng))
                rect = rect.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 0, height: 0))
            }
        }
        if rect.isNull {
            for annotation in annotations {
                let mapPoint = MKMapPoint(annotation.coordinate)
                rect = rect.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 0, height: 0))
            }
        }
        guard !rect.isNull else { return }

        // A lone point has zero extent, which MapKit reads as "zoom in as far
        // as possible". Give it a real footprint so it lands at block scale.
        if rect.size.width < 1, rect.size.height < 1 {
            let metresPerPoint = MKMapPointsPerMeterAtLatitude(
                MKMapPoint(x: rect.origin.x, y: rect.origin.y).coordinate.latitude
            )
            let padding = metresPerPoint * 120
            rect = rect.insetBy(dx: -padding, dy: -padding)
        }

        mapView.setVisibleMapRect(
            rect,
            edgePadding: UIEdgeInsets(top: 48, left: 32, bottom: 48, right: 32),
            animated: false
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var focusKey: String = ""
        var onSelectObservation: ((ELRipeness.Observation) -> Void)?

        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let heat = overlay as? ELRipenessHeatOverlay {
                return ELRipenessHeatOverlayRenderer(overlay: heat)
            }
            if let outline = overlay as? ELRipenessBlockOutline {
                let renderer = MKPolygonRenderer(polygon: outline)
                renderer.fillColor = .clear
                renderer.strokeColor = outline.isSelected
                    ? UIColor.white.withAlphaComponent(0.95)
                    : UIColor.white.withAlphaComponent(0.55)
                renderer.lineWidth = outline.isSelected ? 2.5 : 1.5
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let label = annotation as? ELRipenessBlockLabelAnnotation {
                return blockLabelView(mapView: mapView, annotation: label)
            }
            if let observation = annotation as? ELRipenessObservationAnnotation {
                return observationView(mapView: mapView, annotation: observation)
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? ELRipenessObservationAnnotation else { return }
            mapView.deselectAnnotation(view.annotation, animated: false)
            onSelectObservation?(annotation.observation)
        }

        private func blockLabelView(
            mapView: MKMapView,
            annotation: ELRipenessBlockLabelAnnotation
        ) -> MKAnnotationView {
            let identifier = "ripeness.blockLabel"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = false
            view.isEnabled = false
            view.displayPriority = .defaultHigh
            view.image = ELRipenessPinFactory.blockLabelImage(
                name: annotation.name,
                medianEl: annotation.medianEl,
                mode: annotation.mode
            )
            view.accessibilityLabel = ELRipenessPinFactory.blockLabelAccessibility(
                name: annotation.name,
                medianEl: annotation.medianEl,
                mode: annotation.mode
            )
            return view
        }

        private func observationView(
            mapView: MKMapView,
            annotation: ELRipenessObservationAnnotation
        ) -> MKAnnotationView {
            let identifier = "ripeness.observation"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = false
            view.isEnabled = true
            // Pins always sit above the heat surface.
            view.displayPriority = .required
            view.zPriority = .max
            view.image = ELRipenessPinFactory.observationImage(
                el: annotation.observation.el,
                style: annotation.style
            )
            view.accessibilityLabel = ELRipenessPinFactory.observationAccessibility(
                el: annotation.observation.el,
                style: annotation.style,
                blockName: annotation.blockName,
                ageDays: annotation.ageDays
            )
            return view
        }
    }
}
